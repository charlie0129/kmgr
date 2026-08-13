// Package columns implements kmgr.cel/v1 programmable resource columns.
package columns

import (
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/common/types/traits"
)

const (
	EnvironmentVersion = "kmgr.cel/v1"
	DefaultCostLimit   = uint64(10_000)
	MaxListElements    = 128
	MaxDisplayBytes    = 4 * 1024
	DefaultMissing     = "—"
)

type ResultType string

const (
	ResultString    ResultType = "string"
	ResultInteger   ResultType = "integer"
	ResultNumber    ResultType = "number"
	ResultBoolean   ResultType = "boolean"
	ResultQuantity  ResultType = "quantity"
	ResultTimestamp ResultType = "timestamp"
	ResultDuration  ResultType = "duration"
)

type Definition struct {
	ID         string
	Title      string
	Expression string
	ResultType ResultType
	Missing    string
	ListJoiner string
}

type Activation struct {
	Object  map[string]any
	Metrics map[string]any
	Context map[string]any
	Now     time.Time
}

type Value struct {
	Display  string
	String   *string
	Integer  *int64
	Number   *float64
	Boolean  *bool
	Time     *time.Time
	Duration *time.Duration
}

type RuntimeError struct {
	ColumnID string
	Err      error
}

func (e *RuntimeError) Error() string {
	return fmt.Sprintf("column %q: %v", e.ColumnID, e.Err)
}

func (e *RuntimeError) Unwrap() error { return e.Err }

type Compiler struct {
	environment *cel.Env
	costLimit   uint64
}

type Program struct {
	definition Definition
	program    cel.Program
}

// Definition returns the immutable, validated definition used to compile the
// program. Callers use this metadata to preserve declared result types without
// reparsing rendered values.
func (p *Program) Definition() Definition {
	if p == nil {
		return Definition{}
	}
	return p.definition
}

func NewCompiler(costLimit uint64) (*Compiler, error) {
	if costLimit == 0 {
		return nil, errors.New("CEL cost limit must be positive")
	}
	environment, err := cel.NewEnv(
		cel.OptionalTypes(),
		cel.Variable("object", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("metrics", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("context", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("now", cel.TimestampType),
	)
	if err != nil {
		return nil, fmt.Errorf("create CEL environment: %w", err)
	}
	return &Compiler{environment: environment, costLimit: costLimit}, nil
}

func (c *Compiler) Compile(definition Definition) (*Program, error) {
	if strings.TrimSpace(definition.ID) == "" {
		return nil, errors.New("column ID must not be empty")
	}
	if strings.TrimSpace(definition.Expression) == "" {
		return nil, fmt.Errorf("column %q expression must not be empty", definition.ID)
	}
	if !validResultType(definition.ResultType) {
		return nil, fmt.Errorf("column %q has unsupported result type %q", definition.ID, definition.ResultType)
	}
	if definition.Missing == "" {
		definition.Missing = DefaultMissing
	}
	if definition.ListJoiner == "" {
		definition.ListJoiner = ", "
	}

	ast, issues := c.environment.Compile(definition.Expression)
	if err := issues.Err(); err != nil {
		return nil, fmt.Errorf("compile column %q: %w", definition.ID, err)
	}
	if err := validateStaticType(ast.OutputType(), definition.ResultType); err != nil {
		return nil, fmt.Errorf("column %q: %w", definition.ID, err)
	}
	program, err := c.environment.Program(ast, cel.CostLimit(c.costLimit))
	if err != nil {
		return nil, fmt.Errorf("build column %q program: %w", definition.ID, err)
	}
	return &Program{definition: definition, program: program}, nil
}

func (p *Program) Evaluate(activation Activation) (Value, error) {
	if activation.Object == nil {
		activation.Object = map[string]any{}
	}
	if activation.Metrics == nil {
		activation.Metrics = map[string]any{}
	}
	if activation.Context == nil {
		activation.Context = map[string]any{}
	}
	result, _, err := p.program.Eval(map[string]any{
		"object":  activation.Object,
		"metrics": activation.Metrics,
		"context": activation.Context,
		"now":     activation.Now,
	})
	if err != nil {
		return Value{}, &RuntimeError{ColumnID: p.definition.ID, Err: err}
	}
	value, err := p.coerce(result)
	if err != nil {
		return Value{}, &RuntimeError{ColumnID: p.definition.ID, Err: err}
	}
	return value, nil
}

func (p *Program) coerce(result ref.Val) (Value, error) {
	if result == nil || result == types.NullValue || types.IsUnknownOrError(result) {
		return Value{Display: p.definition.Missing}, nil
	}
	if optional, ok := result.(*types.Optional); ok {
		if !optional.HasValue() {
			return Value{Display: p.definition.Missing}, nil
		}
		result = optional.GetValue()
	}

	switch p.definition.ResultType {
	case ResultString, ResultQuantity:
		if list, ok := result.(traits.Lister); ok {
			return p.stringList(list)
		}
		if value, ok := result.(types.String); ok {
			text := string(value)
			if err := validateOutput(text); err != nil {
				return Value{}, err
			}
			return Value{Display: text, String: &text}, nil
		}
		return Value{}, typeMismatch(p.definition.ResultType, result)
	case ResultInteger:
		value, ok := result.(types.Int)
		if !ok {
			return Value{}, typeMismatch(p.definition.ResultType, result)
		}
		integer := int64(value)
		return Value{Display: fmt.Sprintf("%d", integer), Integer: &integer}, nil
	case ResultNumber:
		var number float64
		switch value := result.(type) {
		case types.Double:
			number = float64(value)
		case types.Int:
			number = float64(value)
		case types.Uint:
			number = float64(value)
		default:
			return Value{}, typeMismatch(p.definition.ResultType, result)
		}
		if math.IsNaN(number) || math.IsInf(number, 0) {
			return Value{}, errors.New("numeric result is not finite")
		}
		return Value{Display: fmt.Sprintf("%g", number), Number: &number}, nil
	case ResultBoolean:
		value, ok := result.(types.Bool)
		if !ok {
			return Value{}, typeMismatch(p.definition.ResultType, result)
		}
		boolean := bool(value)
		return Value{Display: fmt.Sprintf("%t", boolean), Boolean: &boolean}, nil
	case ResultTimestamp:
		native, err := result.ConvertToNative(reflect.TypeFor[time.Time]())
		if err != nil {
			return Value{}, typeMismatch(p.definition.ResultType, result)
		}
		value := native.(time.Time)
		return Value{Display: value.Format(time.RFC3339), Time: &value}, nil
	case ResultDuration:
		native, err := result.ConvertToNative(reflect.TypeFor[time.Duration]())
		if err != nil {
			return Value{}, typeMismatch(p.definition.ResultType, result)
		}
		value := native.(time.Duration)
		return Value{Display: value.String(), Duration: &value}, nil
	default:
		return Value{}, fmt.Errorf("unsupported result type %q", p.definition.ResultType)
	}
}

func (p *Program) stringList(list traits.Lister) (Value, error) {
	size, ok := list.Size().(types.Int)
	if !ok {
		return Value{}, errors.New("list has no integer size")
	}
	if size > MaxListElements {
		return Value{}, fmt.Errorf("list result has %d elements; maximum is %d", size, MaxListElements)
	}
	values := make([]string, 0, int(size))
	iterator := list.Iterator()
	for iterator.HasNext() == types.True {
		element := iterator.Next()
		switch scalar := element.(type) {
		case types.String:
			values = append(values, string(scalar))
		case types.Int:
			values = append(values, fmt.Sprintf("%d", int64(scalar)))
		case types.Uint:
			values = append(values, fmt.Sprintf("%d", uint64(scalar)))
		case types.Double:
			values = append(values, fmt.Sprintf("%g", float64(scalar)))
		case types.Bool:
			values = append(values, fmt.Sprintf("%t", bool(scalar)))
		default:
			return Value{}, fmt.Errorf("list result contains non-scalar %s", element.Type().TypeName())
		}
	}
	text := strings.Join(values, p.definition.ListJoiner)
	if err := validateOutput(text); err != nil {
		return Value{}, err
	}
	return Value{Display: text, String: &text}, nil
}

func validateOutput(value string) error {
	if !utf8.ValidString(value) {
		return errors.New("string result is not valid UTF-8")
	}
	if len(value) > MaxDisplayBytes {
		return fmt.Errorf("display result is %d bytes; maximum is %d", len(value), MaxDisplayBytes)
	}
	return nil
}

func typeMismatch(want ResultType, value ref.Val) error {
	return fmt.Errorf("result type is %s, declared %s", value.Type().TypeName(), want)
}

func validResultType(resultType ResultType) bool {
	switch resultType {
	case ResultString, ResultInteger, ResultNumber, ResultBoolean, ResultQuantity, ResultTimestamp, ResultDuration:
		return true
	default:
		return false
	}
}

func validateStaticType(actual *cel.Type, declared ResultType) error {
	if actual == cel.DynType || actual == cel.NullType {
		return nil
	}
	if actual.TypeName() == "optional_type" {
		parameters := actual.Parameters()
		if len(parameters) == 1 {
			return validateStaticType(parameters[0], declared)
		}
		return nil
	}

	wants := []*cel.Type{}
	switch declared {
	case ResultString, ResultQuantity:
		wants = []*cel.Type{cel.StringType, cel.ListType(cel.DynType)}
	case ResultInteger:
		wants = []*cel.Type{cel.IntType}
	case ResultNumber:
		wants = []*cel.Type{cel.IntType, cel.UintType, cel.DoubleType}
	case ResultBoolean:
		wants = []*cel.Type{cel.BoolType}
	case ResultTimestamp:
		wants = []*cel.Type{cel.TimestampType}
	case ResultDuration:
		wants = []*cel.Type{cel.DurationType}
	}
	for _, want := range wants {
		if want.IsAssignableType(actual) || actual.IsAssignableType(want) {
			return nil
		}
	}
	return fmt.Errorf("expression has static type %s, incompatible with declared %s", actual, declared)
}

// SanitizeObjectActivation makes a shallow path copy and removes Secret
// payload fields. It is the security boundary for CEL activation: callers must
// pass isSecret from the authoritative GVR/GVK, not infer it from expressions.
func SanitizeObjectActivation(object map[string]any, isSecret bool) map[string]any {
	copy := cloneMap(object)
	if isSecret {
		delete(copy, "data")
		delete(copy, "stringData")
	}
	return copy
}

func cloneMap(value map[string]any) map[string]any {
	copy := make(map[string]any, len(value))
	for key, item := range value {
		switch typed := item.(type) {
		case map[string]any:
			copy[key] = cloneMap(typed)
		case []any:
			items := make([]any, len(typed))
			for index, child := range typed {
				if childMap, ok := child.(map[string]any); ok {
					items[index] = cloneMap(childMap)
				} else {
					items[index] = child
				}
			}
			copy[key] = items
		default:
			copy[key] = item
		}
	}
	return copy
}
