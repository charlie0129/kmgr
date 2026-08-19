package watcher

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/rest"
)

const tableAcceptHeader = "application/json;as=Table;v=v1;g=meta.k8s.io,application/json;as=Table;v=v1beta1;g=meta.k8s.io"

// TableList is one decoded metav1.Table page. Objects and Cells share an
// index only through UID, so the full objects can enter UIDStore while the
// compact server values remain a presentation sidecar.
type TableList struct {
	ResourceVersion string
	Continue        string
	Objects         []*unstructured.Unstructured
	Columns         []metav1.TableColumnDefinition
	Cells           map[types.UID][]any
	ServerTable     bool
}

// TableListerWatcher extends an ordinary dynamic client with Table content
// negotiation. Implementations fall back to the ordinary methods after a
// server rejects or malforms Table output; the pipeline still owns exactly one
// active LIST/WATCH stream for the requested GVR.
type TableListerWatcher interface {
	ListerWatcher
	ListTable(context.Context, metav1.ListOptions) (*TableList, error)
	WatchTable(context.Context, metav1.ListOptions) (watch.Interface, error)
	TableEnabled() bool
	DisableTable()
}

type TableResourceClient struct {
	rest      rest.Interface
	fallback  ListerWatcher
	resource  string
	namespace string
	include   metav1.IncludeObjectPolicy
	disabled  atomic.Bool
}

func NewTableResourceClient(
	config *rest.Config,
	gvr schema.GroupVersionResource,
	namespace string,
	fallback ListerWatcher,
	include metav1.IncludeObjectPolicy,
) (*TableResourceClient, error) {
	if config == nil {
		return nil, errors.New("table resource client requires a REST config")
	}
	if fallback == nil {
		return nil, errors.New("table resource client requires a fallback client")
	}
	if include != metav1.IncludeObject && include != metav1.IncludeMetadata {
		return nil, fmt.Errorf("unsupported Table includeObject policy %q", include)
	}
	copy := rest.CopyConfig(config)
	groupVersion := gvr.GroupVersion()
	copy.GroupVersion = &groupVersion
	if gvr.Group == "" {
		copy.APIPath = "/api"
	} else {
		copy.APIPath = "/apis"
	}
	scheme := runtime.NewScheme()
	metav1.AddToGroupVersion(scheme, groupVersion)
	if err := metav1.AddMetaToScheme(scheme); err != nil {
		return nil, fmt.Errorf("register Table types: %w", err)
	}
	// Some aggregated apiservers return the requested resource GroupVersion in
	// TypeMeta even though the negotiated representation is a meta.k8s.io Table.
	scheme.AddKnownTypes(groupVersion, &metav1.Table{}, &metav1.TableOptions{})
	copy.NegotiatedSerializer = serializer.NewCodecFactory(scheme).WithoutConversion()
	client, err := rest.RESTClientFor(copy)
	if err != nil {
		return nil, fmt.Errorf("construct Table REST client: %w", err)
	}
	return &TableResourceClient{
		rest: client, fallback: fallback, resource: gvr.Resource, namespace: namespace,
		include: include,
	}, nil
}

func (c *TableResourceClient) List(ctx context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	return c.fallback.List(ctx, options)
}

func (c *TableResourceClient) Watch(ctx context.Context, options metav1.ListOptions) (watch.Interface, error) {
	return c.fallback.Watch(ctx, options)
}

func (c *TableResourceClient) TableEnabled() bool { return c != nil && !c.disabled.Load() }

func (c *TableResourceClient) DisableTable() {
	if c != nil {
		c.disabled.Store(true)
	}
}

func (c *TableResourceClient) ListTable(ctx context.Context, options metav1.ListOptions) (*TableList, error) {
	if !c.TableEnabled() {
		return c.listFallback(ctx, options)
	}
	options.Watch = false
	request := c.rest.Get().
		SetHeader("Accept", tableAcceptHeader).
		Namespace(c.namespace).
		Resource(c.resource).
		Param("includeObject", string(c.include)).
		VersionedParams(&options, metav1.ParameterCodec)
	table := &metav1.Table{}
	if err := request.Do(ctx).Into(table); err != nil {
		c.DisableTable()
		return c.listFallback(ctx, options)
	}
	result, err := decodeTableList(table)
	if err != nil {
		c.DisableTable()
		return c.listFallback(ctx, options)
	}
	return result, nil
}

func (c *TableResourceClient) WatchTable(ctx context.Context, options metav1.ListOptions) (watch.Interface, error) {
	if !c.TableEnabled() {
		return c.fallback.Watch(ctx, options)
	}
	options.Watch = true
	stream, err := c.rest.Get().
		SetHeader("Accept", tableAcceptHeader).
		Namespace(c.namespace).
		Resource(c.resource).
		Param("includeObject", string(c.include)).
		VersionedParams(&options, metav1.ParameterCodec).
		Watch(ctx)
	if err == nil {
		return stream, nil
	}
	c.DisableTable()
	return c.fallback.Watch(ctx, options)
}

func (c *TableResourceClient) listFallback(ctx context.Context, options metav1.ListOptions) (*TableList, error) {
	list, err := c.fallback.List(ctx, options)
	if err != nil {
		return nil, err
	}
	if list == nil {
		return nil, errors.New("server returned a nil fallback list")
	}
	objects := make([]*unstructured.Unstructured, 0, len(list.Items))
	for index := range list.Items {
		objects = append(objects, &list.Items[index])
	}
	return &TableList{
		ResourceVersion: list.GetResourceVersion(), Continue: list.GetContinue(), Objects: objects,
	}, nil
}

func decodeTableList(table *metav1.Table) (*TableList, error) {
	if table == nil {
		return nil, errors.New("server returned a nil Table")
	}
	if table.GetResourceVersion() == "" {
		return nil, errors.New("Table page has no resourceVersion")
	}
	result := &TableList{
		ResourceVersion: table.GetResourceVersion(), Continue: table.GetContinue(),
		Columns: append([]metav1.TableColumnDefinition(nil), table.ColumnDefinitions...),
		Objects: make([]*unstructured.Unstructured, 0, len(table.Rows)),
		Cells:   make(map[types.UID][]any, len(table.Rows)), ServerTable: true,
	}
	for index := range table.Rows {
		row := &table.Rows[index]
		if len(row.Cells) != len(table.ColumnDefinitions) {
			return nil, fmt.Errorf(
				"Table row %d has %d cells for %d columns",
				index, len(row.Cells), len(table.ColumnDefinitions),
			)
		}
		object, err := decodeTableObject(row)
		if err != nil {
			return nil, fmt.Errorf("decode Table row %d object: %w", index, err)
		}
		if object.GetUID() == "" {
			return nil, fmt.Errorf("Table row %d object has no UID", index)
		}
		result.Objects = append(result.Objects, object)
		result.Cells[object.GetUID()] = append([]any(nil), row.Cells...)
	}
	return result, nil
}

func decodeTableObject(row *metav1.TableRow) (*unstructured.Unstructured, error) {
	if row == nil {
		return nil, errors.New("nil row")
	}
	if object, ok := row.Object.Object.(*unstructured.Unstructured); ok && object != nil {
		return object, nil
	}
	if row.Object.Object != nil {
		value, err := runtime.DefaultUnstructuredConverter.ToUnstructured(row.Object.Object)
		if err != nil {
			return nil, fmt.Errorf("convert Table row object %T: %w", row.Object.Object, err)
		}
		return &unstructured.Unstructured{Object: value}, nil
	}
	if len(row.Object.Raw) == 0 {
		return nil, errors.New("Table row object is absent despite includeObject policy")
	}
	decoded, err := runtime.Decode(unstructured.UnstructuredJSONScheme, row.Object.Raw)
	if err != nil {
		return nil, err
	}
	object, ok := decoded.(*unstructured.Unstructured)
	if !ok {
		return nil, fmt.Errorf("row object decoded as %T", decoded)
	}
	return object, nil
}
