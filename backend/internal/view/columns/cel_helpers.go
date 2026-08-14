package columns

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/checker"
	commonast "github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/common/types/traits"
	"github.com/google/cel-go/interpreter"
)

const (
	sumDynOverload   = "kmgr_sum_list_dyn"
	joinOverload     = "kmgr_join_list_dyn_string"
	joinCallBaseCost = uint64(1)
)

// kmgrLibrary is the bounded pure helper surface attached to kmgr.cel/v1.
// Fully-qualified names avoid collisions with future CEL standard libraries.
type kmgrLibrary struct{}

func (kmgrLibrary) LibraryName() string { return EnvironmentVersion + "/helpers" }

func (kmgrLibrary) CompileOptions() []cel.EnvOption {
	return []cel.EnvOption{
		cel.Function(SumFunctionName,
			cel.Overload(sumDynOverload, []*cel.Type{cel.ListType(cel.DynType)}, cel.DynType,
				cel.UnaryBinding(sumDynamicList)),
		),
		cel.Function(JoinFunctionName,
			cel.Overload(joinOverload, []*cel.Type{cel.ListType(cel.DynType), cel.StringType}, cel.StringType,
				cel.BinaryBinding(joinScalarList)),
		),
		cel.ASTValidators(kmgrHelperValidator{}),
		cel.CostEstimatorOptions(
			checker.OverloadCostEstimate(sumDynOverload, estimateListTraversal),
			checker.OverloadCostEstimate(joinOverload, estimateJoin),
		),
	}
}

func (kmgrLibrary) ProgramOptions() []cel.ProgramOption {
	return []cel.ProgramOption{cel.CostTrackerOptions(
		interpreter.OverloadCostTracker(sumDynOverload, trackListTraversal),
		interpreter.OverloadCostTracker(joinOverload, trackJoin),
	)}
}

type kmgrHelperValidator struct{}

func (kmgrHelperValidator) Name() string { return EnvironmentVersion + "/helper-validator" }

func (kmgrHelperValidator) Validate(_ *cel.Env, _ cel.ValidatorConfig, ast *commonast.AST, issues *cel.Issues) {
	root := commonast.NavigateAST(ast)
	for _, expression := range commonast.MatchDescendants(root, commonast.KindMatcher(commonast.CallKind)) {
		call := expression.AsCall()
		if call.FunctionName() != SumFunctionName && call.FunctionName() != JoinFunctionName {
			continue
		}
		args := call.Args()
		if len(args) == 0 {
			continue
		}
		if list := args[0]; list.Kind() == commonast.ListKind && list.AsList().Size() > MaxListElements {
			issues.ReportErrorAtID(list.ID(), "%s accepts at most %d list elements", call.FunctionName(), MaxListElements)
		}
		if call.FunctionName() == SumFunctionName {
			validateStaticSumType(ast, args[0], issues)
		}
	}
}

func validateStaticSumType(ast *commonast.AST, argument commonast.Expr, issues *cel.Issues) {
	argumentType := ast.GetType(argument.ID())
	if argumentType == types.DynType {
		return
	}
	if argumentType.Kind() != types.ListKind || len(argumentType.Parameters()) != 1 {
		return
	}
	elementType := argumentType.Parameters()[0]
	if elementType != types.DynType && elementType != types.IntType &&
		elementType != types.UintType && elementType != types.DoubleType {
		issues.ReportErrorAtID(argument.ID(), "%s requires a list of int, uint, or double; got %s", SumFunctionName, argumentType)
	}
}

func boundedList(value ref.Val, helper string) (traits.Lister, int, ref.Val) {
	if value == nil {
		return nil, 0, types.NewErr("%s requires a list; got nil", helper)
	}
	if types.IsUnknownOrError(value) {
		return nil, 0, value
	}
	list, ok := value.(traits.Lister)
	if !ok {
		return nil, 0, types.NewErr("%s requires a list", helper)
	}
	size, ok := list.Size().(types.Int)
	if !ok || size < 0 {
		return nil, 0, types.NewErr("%s list has no valid integer size", helper)
	}
	if size > MaxListElements {
		return nil, 0, types.NewErr("%s list has %d elements; maximum is %d", helper, size, MaxListElements)
	}
	return list, int(size), nil
}

func sumIntList(value ref.Val) ref.Val {
	list, size, errValue := boundedList(value, SumFunctionName)
	if errValue != nil {
		return errValue
	}
	total := types.IntZero
	for index := 0; index < size; index++ {
		element := list.Get(types.Int(index))
		if errValue := helperElementError(element, index); errValue != nil {
			return errValue
		}
		integer, ok := element.(types.Int)
		if !ok {
			return types.NewErr("%s element %d is %s; expected int", SumFunctionName, index, safeTypeName(element))
		}
		result := total.Add(integer)
		if types.IsError(result) {
			return result
		}
		total = result.(types.Int)
	}
	return total
}

func sumUintList(value ref.Val) ref.Val {
	list, size, errValue := boundedList(value, SumFunctionName)
	if errValue != nil {
		return errValue
	}
	total := types.Uint(0)
	for index := 0; index < size; index++ {
		element := list.Get(types.Int(index))
		if errValue := helperElementError(element, index); errValue != nil {
			return errValue
		}
		integer, ok := element.(types.Uint)
		if !ok {
			return types.NewErr("%s element %d is %s; expected uint", SumFunctionName, index, safeTypeName(element))
		}
		result := total.Add(integer)
		if types.IsError(result) {
			return result
		}
		total = result.(types.Uint)
	}
	return total
}

func sumDoubleList(value ref.Val) ref.Val {
	list, size, errValue := boundedList(value, SumFunctionName)
	if errValue != nil {
		return errValue
	}
	total := types.Double(0)
	for index := 0; index < size; index++ {
		element := list.Get(types.Int(index))
		if errValue := helperElementError(element, index); errValue != nil {
			return errValue
		}
		number, ok := element.(types.Double)
		if !ok {
			return types.NewErr("%s element %d is %s; expected double", SumFunctionName, index, safeTypeName(element))
		}
		total += number
		if math.IsNaN(float64(total)) || math.IsInf(float64(total), 0) {
			return types.NewErr("%s result is not finite", SumFunctionName)
		}
	}
	return total
}

func sumDynamicList(value ref.Val) ref.Val {
	list, size, errValue := boundedList(value, SumFunctionName)
	if errValue != nil {
		return errValue
	}
	if size == 0 {
		return types.IntZero
	}
	first := list.Get(types.IntZero)
	if errValue := helperElementError(first, 0); errValue != nil {
		return errValue
	}
	switch first.(type) {
	case types.Int:
		return sumIntList(value)
	case types.Uint:
		return sumUintList(value)
	case types.Double:
		return sumDoubleList(value)
	default:
		return types.NewErr("%s element 0 is %s; expected int, uint, or double", SumFunctionName, safeTypeName(first))
	}
}

func joinScalarList(listValue, separatorValue ref.Val) ref.Val {
	list, size, errValue := boundedList(listValue, JoinFunctionName)
	if errValue != nil {
		return errValue
	}
	separator, ok := separatorValue.(types.String)
	if !ok {
		return types.NewErr("%s separator must be a string", JoinFunctionName)
	}
	separatorText := string(separator)
	if !utf8.ValidString(separatorText) {
		return types.NewErr("%s separator is not valid UTF-8", JoinFunctionName)
	}
	var builder strings.Builder
	for index := 0; index < size; index++ {
		if index > 0 && !boundedWrite(&builder, separatorText) {
			return helperOutputLimitError()
		}
		element := list.Get(types.Int(index))
		if errValue := helperElementError(element, index); errValue != nil {
			return errValue
		}
		text, ok := scalarText(element)
		if !ok {
			return types.NewErr("%s element %d is non-scalar %s", JoinFunctionName, index, safeTypeName(element))
		}
		if !utf8.ValidString(text) {
			return types.NewErr("%s element %d is not valid UTF-8", JoinFunctionName, index)
		}
		if !boundedWrite(&builder, text) {
			return helperOutputLimitError()
		}
	}
	return types.String(builder.String())
}

func helperElementError(value ref.Val, index int) ref.Val {
	if value == nil {
		return types.NewErr("kmgr helper list element %d is nil", index)
	}
	if types.IsUnknownOrError(value) {
		return value
	}
	return nil
}

func safeTypeName(value ref.Val) string {
	if value == nil || value.Type() == nil {
		return "nil"
	}
	return value.Type().TypeName()
}

func scalarText(value ref.Val) (string, bool) {
	switch scalar := value.(type) {
	case types.String:
		return string(scalar), true
	case types.Int:
		return fmt.Sprintf("%d", int64(scalar)), true
	case types.Uint:
		return fmt.Sprintf("%d", uint64(scalar)), true
	case types.Double:
		return fmt.Sprintf("%g", float64(scalar)), true
	case types.Bool:
		return fmt.Sprintf("%t", bool(scalar)), true
	default:
		return "", false
	}
}

func boundedWrite(builder *strings.Builder, value string) bool {
	if len(value) > MaxDisplayBytes-builder.Len() {
		return false
	}
	builder.WriteString(value)
	return true
}

func helperOutputLimitError() ref.Val {
	return types.NewErr("%s result exceeds maximum of %d bytes", JoinFunctionName, MaxDisplayBytes)
}

func estimateListSize(estimator checker.CostEstimator, node checker.AstNode) checker.SizeEstimate {
	if size := node.ComputedSize(); size != nil {
		return *size
	}
	if size := estimator.EstimateSize(node); size != nil {
		return *size
	}
	return checker.SizeEstimate{Min: 0, Max: MaxListElements}
}

func estimateListTraversal(estimator checker.CostEstimator, _ *checker.AstNode, args []checker.AstNode) *checker.CallEstimate {
	if len(args) != 1 {
		return nil
	}
	size := estimateListSize(estimator, args[0])
	return &checker.CallEstimate{CostEstimate: size.AsCost().Add(checker.FixedCostEstimate(1))}
}

func estimateJoin(estimator checker.CostEstimator, _ *checker.AstNode, args []checker.AstNode) *checker.CallEstimate {
	if len(args) != 2 {
		return nil
	}
	listSize := estimateListSize(estimator, args[0])
	resultSize := checker.SizeEstimate{Min: 0, Max: MaxDisplayBytes}
	cost := listSize.AsCost().Add(resultSize.AsCost()).Add(checker.FixedCostEstimate(joinCallBaseCost))
	return &checker.CallEstimate{CostEstimate: cost, ResultSize: &resultSize}
}

func trackListTraversal(args []ref.Val, _ ref.Val) *uint64 {
	cost := joinCallBaseCost
	if len(args) > 0 {
		if list, ok := args[0].(traits.Sizer); ok {
			if size, ok := list.Size().(types.Int); ok && size > 0 {
				cost += uint64(size)
			}
		}
	}
	return &cost
}

func trackJoin(args []ref.Val, result ref.Val) *uint64 {
	cost := *trackListTraversal(args, result)
	if text, ok := result.(types.String); ok {
		cost += uint64(len(text))
	}
	return &cost
}
