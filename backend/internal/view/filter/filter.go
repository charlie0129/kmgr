// Package filter implements kmgr's resource-list query grammar. Local terms
// stay deliberately small; explicitly prefixed Kubernetes selectors delegate
// their native syntax to the Kubernetes selector parsers. It performs no
// shell evaluation and compiles a query once for reuse.
package filter

import (
	"cmp"
	"fmt"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
)

type Kind uint8

const (
	Text Kind = iota
	Namespace
	Name
	Label
	Field
	Status
	Column
	NativeLabel
	NativeField
)

type Term struct {
	Kind  Kind
	Key   string
	Value string
	Exact bool
}

type Filter struct {
	terms           []Term
	compiled        []compiledTerm
	columnTermCount int
}

type compiledTerm struct {
	term          Term
	labelSelector labels.Selector
	fieldSelector fields.Selector
	columnIndex   int
}

type columnMatcher struct {
	id    string
	index int
}

type ParseError struct {
	Offset  int
	Message string
}

func (e *ParseError) Error() string {
	return fmt.Sprintf("filter at byte %d: %s", e.Offset, e.Message)
}

type Candidate struct {
	Namespace   string
	Name        string
	Status      string
	Labels      map[string]string
	Fields      map[string]string
	VisibleText []string
	// VisibleColumnTexts is ordered exactly like the active column IDs supplied
	// to CompileForColumns. It is populated only when the query contains a
	// column-qualified term, keeping ordinary text filters allocation-light.
	VisibleColumnTexts []string
}

func Compile(input string) (*Filter, error) {
	return CompileForColumns(input, nil)
}

// CompileForColumns compiles one query with the currently projected column
// IDs. Column-qualified terms use these IDs to resolve both the convenient
// `<id>:<value>` spelling and the unambiguous `column:<id>:<value>` spelling.
// The ordinary Compile entry point intentionally has no column context and
// therefore rejects column-qualified terms.
func CompileForColumns(input string, columnIDs []string) (*Filter, error) {
	tokens, err := tokenize(input)
	if err != nil {
		return nil, err
	}
	columnIndexes := make(map[string]int, len(columnIDs))
	columnMatchers := make([]columnMatcher, 0, len(columnIDs))
	for index, id := range columnIDs {
		if _, exists := columnIndexes[id]; exists {
			continue
		}
		columnIndexes[id] = index
		columnMatchers = append(columnMatchers, columnMatcher{id: id, index: index})
	}
	// Longest IDs win when a custom ID itself contains a colon and therefore
	// shares a prefix with another ID. IDs remain case-sensitive, just like
	// the column protocol identity.
	slices.SortStableFunc(columnMatchers, func(left, right columnMatcher) int {
		if len(left.id) != len(right.id) {
			return cmp.Compare(len(right.id), len(left.id))
		}
		return cmp.Compare(left.id, right.id)
	})
	compiled := &Filter{
		terms:    make([]Term, 0, len(tokens)),
		compiled: make([]compiledTerm, 0, len(tokens)),
	}
	for _, token := range tokens {
		term, err := parseTerm(token, columnIndexes, columnMatchers)
		if err != nil {
			return nil, err
		}
		if term.term.Kind == Column {
			compiled.columnTermCount++
		}
		compiled.terms = append(compiled.terms, term.term)
		compiled.compiled = append(compiled.compiled, term)
	}
	return compiled, nil
}

func (f *Filter) Terms() []Term {
	return append([]Term(nil), f.terms...)
}

// ColumnIDs returns the column IDs referenced by column-qualified terms in
// query order, without duplicates.
func (f *Filter) ColumnIDs() []string {
	if f == nil || f.columnTermCount == 0 {
		return nil
	}
	result := make([]string, 0, f.columnTermCount)
	seen := make(map[string]struct{}, f.columnTermCount)
	for _, term := range f.terms {
		if term.Kind != Column {
			continue
		}
		if _, exists := seen[term.Key]; exists {
			continue
		}
		seen[term.Key] = struct{}{}
		result = append(result, term.Key)
	}
	return result
}

// HasColumnTerms reports whether matching requires projected column text.
func (f *Filter) HasColumnTerms() bool {
	return f != nil && f.columnTermCount != 0
}

// NativeLabelSelectors returns the explicitly requested Kubernetes label
// selectors in query order. Local label terms are deliberately excluded: the
// visible query, rather than an inferred transport optimization, controls
// which server-side predicates are applied.
func (f *Filter) NativeLabelSelectors() []string {
	if f == nil {
		return nil
	}
	result := make([]string, 0)
	for _, term := range f.compiled {
		if term.labelSelector != nil {
			result = append(result, term.term.Value)
		}
	}
	return result
}

// NativeFieldSelectors returns the explicitly requested Kubernetes field
// selectors in query order.
func (f *Filter) NativeFieldSelectors() []string {
	if f == nil {
		return nil
	}
	result := make([]string, 0)
	for _, term := range f.compiled {
		if term.fieldSelector != nil {
			result = append(result, term.fieldSelector.String())
		}
	}
	return result
}

// FieldPaths returns every object path needed to evaluate local and native
// field terms. The projection layer uses this to avoid fetching a broad raw
// object merely because the query contains an explicit native field selector.
func (f *Filter) FieldPaths() []string {
	if f == nil {
		return nil
	}
	result := make([]string, 0)
	seen := make(map[string]struct{})
	for _, term := range f.compiled {
		paths := []string(nil)
		switch term.term.Kind {
		case Field:
			paths = []string{term.term.Key}
		case NativeField:
			for _, requirement := range term.fieldSelector.Requirements() {
				paths = append(paths, requirement.Field)
			}
		}
		for _, path := range paths {
			if _, exists := seen[path]; exists {
				continue
			}
			seen[path] = struct{}{}
			result = append(result, path)
		}
	}
	return result
}

func (f *Filter) Match(candidate Candidate) bool {
	if f == nil {
		return true
	}
	for _, term := range f.compiled {
		switch term.term.Kind {
		case NativeLabel:
			if !term.labelSelector.Matches(labels.Set(candidate.Labels)) {
				return false
			}
		case NativeField:
			if !term.fieldSelector.Matches(fields.Set(candidate.Fields)) {
				return false
			}
		case Text, Namespace, Name, Label, Field, Status:
			if !termMatches(term.term, candidate) {
				return false
			}
		case Column:
			if term.columnIndex < 0 || term.columnIndex >= len(candidate.VisibleColumnTexts) ||
				!containsFold(candidate.VisibleColumnTexts[term.columnIndex], term.term.Value) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

type token struct {
	text   string
	offset int
}

func tokenize(input string) ([]token, error) {
	var tokens []token
	for offset := 0; offset < len(input); {
		r, width := utf8.DecodeRuneInString(input[offset:])
		if unicode.IsSpace(r) {
			offset += width
			continue
		}

		start := offset
		var builder strings.Builder
		var quote rune
		nativeSelector := isNativeSelectorToken(input[start:])
		for offset < len(input) {
			r, width = utf8.DecodeRuneInString(input[offset:])
			if quote == 0 && unicode.IsSpace(r) {
				break
			}
			// Native Kubernetes selector bodies use their own backslash
			// escaping for commas, equals, and backslashes. Preserve the body
			// byte-for-byte and let the Kubernetes parser validate it. Quotes
			// still delimit the outer query token; native selector syntax does
			// not use them for its own grammar.
			if nativeSelector {
				if r == '\'' || r == '"' {
					if quote == 0 {
						quote = r
						offset += width
						continue
					}
					if quote == r {
						quote = 0
						offset += width
						continue
					}
				}
				builder.WriteRune(r)
				offset += width
				continue
			}
			if r == '\\' {
				offset += width
				if offset >= len(input) {
					return nil, &ParseError{Offset: offset - 1, Message: "trailing escape"}
				}
				r, width = utf8.DecodeRuneInString(input[offset:])
				builder.WriteRune(r)
				offset += width
				continue
			}
			if r == '\'' || r == '"' {
				if quote == 0 {
					quote = r
					offset += width
					continue
				}
				if quote == r {
					quote = 0
					offset += width
					continue
				}
			}
			builder.WriteRune(r)
			offset += width
		}
		if quote != 0 {
			return nil, &ParseError{Offset: start, Message: "unterminated quote"}
		}
		if builder.Len() != 0 {
			tokens = append(tokens, token{text: builder.String(), offset: start})
		}
	}
	return tokens, nil
}

func isNativeSelectorToken(input string) bool {
	for _, prefix := range []string{"labelselector:", "fieldselector:"} {
		if len(input) >= len(prefix) && strings.EqualFold(input[:len(prefix)], prefix) {
			return true
		}
	}
	return false
}

func parseTerm(
	value token,
	columnIndexes map[string]int,
	columnMatchers []columnMatcher,
) (compiledTerm, error) {
	prefix, body, structured := strings.Cut(value.text, ":")
	if !structured {
		return compiledTerm{term: Term{Kind: Text, Value: fold(value.text)}, columnIndex: -1}, nil
	}
	if body == "" {
		return compiledTerm{}, &ParseError{Offset: value.offset + len(prefix) + 1, Message: "structured term has no value"}
	}

	switch strings.ToLower(prefix) {
	case "namespace", "ns":
		return compiledTerm{term: Term{Kind: Namespace, Value: fold(body)}, columnIndex: -1}, nil
	case "name":
		return compiledTerm{term: Term{Kind: Name, Value: fold(body)}, columnIndex: -1}, nil
	case "status":
		return compiledTerm{term: Term{Kind: Status, Value: fold(body)}, columnIndex: -1}, nil
	case "label":
		term, err := keyedTerm(Label, body, value.offset+len(prefix)+1)
		if err != nil {
			return compiledTerm{}, err
		}
		return compiledTerm{term: term, columnIndex: -1}, nil
	case "field":
		term, err := keyedTerm(Field, body, value.offset+len(prefix)+1)
		if err != nil {
			return compiledTerm{}, err
		}
		return compiledTerm{term: term, columnIndex: -1}, nil
	case "column":
		return parseColumnTerm(
			body,
			value.offset+len(prefix)+1,
			columnIndexes,
			columnMatchers,
		)
	case "labelselector":
		selector, err := labels.Parse(body)
		if err != nil || selector.Empty() {
			message := "Kubernetes label selector must not be empty"
			if err != nil {
				message = fmt.Sprintf("invalid Kubernetes label selector: %v", err)
			}
			return compiledTerm{}, &ParseError{
				Offset:  value.offset + len(prefix) + 1,
				Message: message,
			}
		}
		return compiledTerm{
			term:          Term{Kind: NativeLabel, Value: canonicalLabelSelector(selector)},
			labelSelector: selector,
			columnIndex:   -1,
		}, nil
	case "fieldselector":
		selector, err := fields.ParseSelector(body)
		if err != nil || len(selector.Requirements()) == 0 {
			message := "Kubernetes field selector must not be empty"
			if err != nil {
				message = fmt.Sprintf("invalid Kubernetes field selector: %v", err)
			}
			return compiledTerm{}, &ParseError{
				Offset:  value.offset + len(prefix) + 1,
				Message: message,
			}
		}
		return compiledTerm{
			term:          Term{Kind: NativeField, Value: selector.String()},
			fieldSelector: selector,
			columnIndex:   -1,
		}, nil
	default:
		if id, index, columnValue, exists := matchColumnPrefix(value.text, columnMatchers); exists {
			return columnTerm(id, columnValue, index, value.offset+len(id)+1)
		}
		return compiledTerm{}, &ParseError{Offset: value.offset, Message: fmt.Sprintf("unknown structured term %q", prefix)}
	}
}

func parseColumnTerm(
	body string,
	offset int,
	columnIndexes map[string]int,
	columnMatchers []columnMatcher,
) (compiledTerm, error) {
	if id, index, columnValue, exists := matchColumnPrefix(body, columnMatchers); exists {
		return columnTerm(id, columnValue, index, offset+len(id)+1)
	}
	// Keep an actionable distinction between a missing separator and a typo in
	// the column ID. The latter is intentionally an inline query error.
	columnID, _, hasSeparator := strings.Cut(body, ":")
	if !hasSeparator || columnID == "" {
		return compiledTerm{}, &ParseError{
			Offset:  offset,
			Message: "column term must be column:<id>:<value>",
		}
	}
	if _, exists := columnIndexes[columnID]; !exists {
		return compiledTerm{}, &ParseError{
			Offset:  offset,
			Message: fmt.Sprintf("unknown column %q", columnID),
		}
	}
	return compiledTerm{}, &ParseError{Offset: offset, Message: "column term has no value"}
}

func matchColumnPrefix(value string, matchers []columnMatcher) (string, int, string, bool) {
	for _, matcher := range matchers {
		prefix := matcher.id + ":"
		if !strings.HasPrefix(value, prefix) {
			continue
		}
		return matcher.id, matcher.index, value[len(prefix):], true
	}
	return "", -1, "", false
}

func columnTerm(id, value string, index, offset int) (compiledTerm, error) {
	if value == "" {
		return compiledTerm{}, &ParseError{Offset: offset, Message: "column term has no value"}
	}
	return compiledTerm{
		term:        Term{Kind: Column, Key: id, Value: fold(value)},
		columnIndex: index,
	}, nil
}

func canonicalLabelSelector(selector labels.Selector) string {
	if selector == nil {
		return ""
	}
	requirements, selectable := selector.Requirements()
	if !selectable {
		return selector.String()
	}
	result := make([]string, 0, len(requirements))
	for _, requirement := range requirements {
		operator := requirement.Operator()
		if operator == selection.DoubleEquals {
			operator = selection.Equals
		}
		normalized, err := labels.NewRequirement(
			requirement.Key(), operator, requirement.ValuesUnsorted(),
		)
		if err != nil {
			return selector.String()
		}
		result = append(result, normalized.String())
	}
	return strings.Join(result, ",")
}

func keyedTerm(kind Kind, body string, offset int) (Term, error) {
	key, value, hasValue := strings.Cut(body, "==")
	exact := hasValue
	if !hasValue {
		key, value, hasValue = strings.Cut(body, "=")
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return Term{}, &ParseError{Offset: offset, Message: "key must not be empty"}
	}
	if hasValue && value == "" {
		return Term{}, &ParseError{Offset: offset + len(key) + 1, Message: "value must not be empty"}
	}
	if !exact {
		value = fold(value)
	}
	return Term{Kind: kind, Key: key, Value: value, Exact: exact}, nil
}

func termMatches(term Term, candidate Candidate) bool {
	switch term.Kind {
	case Namespace:
		return containsFold(candidate.Namespace, term.Value)
	case Name:
		return containsFold(candidate.Name, term.Value)
	case Status:
		return containsFold(candidate.Status, term.Value)
	case Label:
		value, ok := candidate.Labels[term.Key]
		return ok && (term.Value == "" || matchesStructuredValue(value, term))
	case Field:
		value, ok := candidate.Fields[term.Key]
		return ok && (term.Value == "" || matchesStructuredValue(value, term))
	case Text:
		if containsFold(candidate.Namespace, term.Value) ||
			containsFold(candidate.Name, term.Value) ||
			containsFold(candidate.Status, term.Value) {
			return true
		}
		for _, text := range candidate.VisibleText {
			if containsFold(text, term.Value) {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func matchesStructuredValue(value string, term Term) bool {
	if term.Exact {
		return value == term.Value
	}
	return containsFold(value, term.Value)
}

func fold(value string) string {
	return strings.ToLower(value)
}

func containsFold(value, foldedNeedle string) bool {
	return strings.Contains(strings.ToLower(value), foldedNeedle)
}
