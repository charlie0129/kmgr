// Package filter implements kmgr's deliberately small resource-list filter
// grammar. It performs no shell evaluation and compiles a query once for reuse.
package filter

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

type Kind uint8

const (
	Text Kind = iota
	Namespace
	Name
	Label
	Field
	Status
)

type Term struct {
	Kind  Kind
	Key   string
	Value string
	Exact bool
}

type Filter struct {
	terms []Term
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
}

func Compile(input string) (*Filter, error) {
	tokens, err := tokenize(input)
	if err != nil {
		return nil, err
	}
	compiled := &Filter{terms: make([]Term, 0, len(tokens))}
	for _, token := range tokens {
		term, err := parseTerm(token)
		if err != nil {
			return nil, err
		}
		compiled.terms = append(compiled.terms, term)
	}
	return compiled, nil
}

func (f *Filter) Terms() []Term {
	return append([]Term(nil), f.terms...)
}

func (f *Filter) Match(candidate Candidate) bool {
	for _, term := range f.terms {
		if !termMatches(term, candidate) {
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
		for offset < len(input) {
			r, width = utf8.DecodeRuneInString(input[offset:])
			if quote == 0 && unicode.IsSpace(r) {
				break
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

func parseTerm(value token) (Term, error) {
	prefix, body, structured := strings.Cut(value.text, ":")
	if !structured {
		return Term{Kind: Text, Value: fold(value.text)}, nil
	}
	if body == "" {
		return Term{}, &ParseError{Offset: value.offset + len(prefix) + 1, Message: "structured term has no value"}
	}

	switch strings.ToLower(prefix) {
	case "namespace", "ns":
		return Term{Kind: Namespace, Value: fold(body)}, nil
	case "name":
		return Term{Kind: Name, Value: fold(body)}, nil
	case "status":
		return Term{Kind: Status, Value: fold(body)}, nil
	case "label":
		return keyedTerm(Label, body, value.offset+len(prefix)+1)
	case "field":
		return keyedTerm(Field, body, value.offset+len(prefix)+1)
	default:
		return Term{}, &ParseError{Offset: value.offset, Message: fmt.Sprintf("unknown structured term %q", prefix)}
	}
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
