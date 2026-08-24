package view

import (
	"errors"
	"slices"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"

	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
)

// queryPlan is the authoritative interpretation of one visible query.
// Kubernetes selector strings are derived transport values: they can only
// come from explicit labelSelector:/fieldSelector: clauses in the filter
// expression and are never supplied as independent view state.
type queryPlan struct {
	filter        *viewfilter.Filter
	labelSelector string
	fieldSelector string
}

func planViewQuery(spec *kmgrv1.ViewSpec) (queryPlan, error) {
	if spec == nil || spec.GetResource() == nil {
		return queryPlan{}, errors.New("view query requires a resource")
	}

	compiled, err := viewfilter.CompileForColumns(
		spec.GetFilterExpression(),
		spec.GetColumnIds(),
	)
	if err != nil {
		return queryPlan{}, err
	}

	return queryPlan{
		filter:        compiled,
		labelSelector: canonicalRequirements(compiled.NativeLabelSelectors()),
		fieldSelector: canonicalRequirements(compiled.NativeFieldSelectors()),
	}, nil
}

// canonicalRequirements sorts and removes only byte-identical Kubernetes-
// rendered requirements. Distinct constraints remain intact; the query
// language deliberately does not infer implications between predicates.
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
