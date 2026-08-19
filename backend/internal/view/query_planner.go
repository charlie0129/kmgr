package view

import (
	"errors"
	"fmt"
	"slices"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"

	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
)

// queryPlan is the authoritative interpretation of one ViewSpec's query.
// filter always retains the complete kmgr expression for final local
// correctness, while the selector strings contain only predicates that are
// safe to apply to Kubernetes LIST/WATCH requests.
type queryPlan struct {
	filter        *viewfilter.Filter
	labelSelector string
	fieldSelector string
}

func planViewQuery(spec *kmgrv1.ViewSpec) (queryPlan, error) {
	if spec == nil || spec.GetResource() == nil {
		return queryPlan{}, errors.New("view query requires a resource")
	}

	compiled, err := viewfilter.Compile(spec.GetFilterExpression())
	if err != nil {
		return queryPlan{}, err
	}
	terms := compiled.Terms()

	labelRequirements, err := parsedLabelRequirements(spec.GetLabelSelector())
	if err != nil {
		return queryPlan{}, fmt.Errorf("parse label selector: %w", err)
	}
	labelRequirements = append(labelRequirements, derivedLabelRequirements(terms)...)

	fieldRequirements, err := parsedFieldRequirements(spec.GetFieldSelector())
	if err != nil {
		return queryPlan{}, fmt.Errorf("parse field selector: %w", err)
	}
	fieldRequirements = append(
		fieldRequirements,
		derivedFieldRequirements(spec.GetResource(), terms)...,
	)

	return queryPlan{
		filter:        compiled,
		labelSelector: canonicalRequirements(labelRequirements),
		fieldSelector: canonicalRequirements(fieldRequirements),
	}, nil
}

func parsedLabelRequirements(value string) ([]string, error) {
	selector, err := labels.Parse(value)
	if err != nil {
		return nil, err
	}
	requirements, selectable := selector.Requirements()
	if !selectable {
		return nil, errors.New("selector cannot select any labels")
	}

	result := make([]string, 0, len(requirements))
	for index := range requirements {
		requirement := requirements[index]
		operator := requirement.Operator()
		if operator == selection.DoubleEquals {
			operator = selection.Equals
		}
		normalized, err := labels.NewRequirement(
			requirement.Key(), operator, requirement.ValuesUnsorted(),
		)
		if err != nil {
			return nil, err
		}
		result = append(result, normalized.String())
	}
	return result, nil
}

func derivedLabelRequirements(terms []viewfilter.Term) []string {
	if len(terms) == 0 {
		return nil
	}
	result := make([]string, 0, len(terms))
	for _, term := range terms {
		if term.Kind != viewfilter.Label {
			continue
		}
		operator := selection.Exists
		var values []string
		switch {
		case term.Value == "":
		case term.Exact:
			operator = selection.Equals
			values = []string{term.Value}
		default:
			continue
		}
		requirement, err := labels.NewRequirement(term.Key, operator, values)
		if err != nil {
			// The kmgr grammar intentionally accepts a wider string space than
			// Kubernetes labels. An invalid native requirement remains covered by
			// the complete local filter instead of turning a valid local query into
			// a malformed API request.
			continue
		}
		result = append(result, requirement.String())
	}
	return result
}

func parsedFieldRequirements(value string) ([]string, error) {
	selector, err := fields.ParseSelector(value)
	if err != nil {
		return nil, err
	}
	requirements := selector.Requirements()
	result := make([]string, 0, len(requirements))
	for _, requirement := range requirements {
		var selector fields.Selector
		switch requirement.Operator {
		case selection.Equals, selection.DoubleEquals:
			selector = fields.OneTermEqualSelector(requirement.Field, requirement.Value)
		case selection.NotEquals:
			selector = fields.OneTermNotEqualSelector(requirement.Field, requirement.Value)
		default:
			return nil, fmt.Errorf(
				"field %q uses unsupported operator %q",
				requirement.Field,
				requirement.Operator,
			)
		}
		result = append(result, selector.String())
	}
	return result, nil
}

func derivedFieldRequirements(
	resource *kmgrv1.ResourceType,
	terms []viewfilter.Term,
) []string {
	if resource == nil || len(terms) == 0 {
		return nil
	}
	result := make([]string, 0, len(terms))
	for _, term := range terms {
		if term.Kind != viewfilter.Field || !term.Exact || term.Value == "" ||
			!pushableFieldPath(resource, term.Key) {
			continue
		}
		result = append(
			result,
			fields.OneTermEqualSelector(term.Key, term.Value).String(),
		)
	}
	return result
}

func pushableFieldPath(resource *kmgrv1.ResourceType, path string) bool {
	switch path {
	case "metadata.name":
		return true
	case "metadata.namespace":
		return resource.GetNamespaced()
	case "spec.nodeName":
		return resource.GetGroup() == "" && resource.GetVersion() == "v1" &&
			resource.GetResource() == "pods"
	case "involvedObject.uid":
		return resource.GetGroup() == "" && resource.GetVersion() == "v1" &&
			resource.GetResource() == "events"
	default:
		return false
	}
}

// canonicalRequirements sorts and removes only byte-identical Kubernetes-
// rendered requirements. Distinct constraints on the same key remain intact;
// query planning deliberately does not grow a predicate-implication engine.
func canonicalRequirements(requirements []string) string {
	if len(requirements) == 0 {
		return ""
	}
	slices.Sort(requirements)
	unique := requirements[:0]
	for _, requirement := range requirements {
		if len(unique) == 0 || unique[len(unique)-1] != requirement {
			unique = append(unique, requirement)
		}
	}
	return strings.Join(unique, ",")
}
