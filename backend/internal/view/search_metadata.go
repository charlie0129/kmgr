package view

import (
	"context"
	"errors"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/metadata"
)

// metadataSearchLister adapts the metadata client's typed list result to the
// identity-only unstructured objects used by the query-independent UID index.
// Labels, annotations, managed fields, and owner references are intentionally
// discarded because explicit-resource search ranks only namespace and name.
type metadataSearchLister struct {
	client metadata.ResourceInterface
}

var _ searchLister = metadataSearchLister{}

func (l metadataSearchLister) Get(
	ctx context.Context,
	name string,
) (*unstructured.Unstructured, error) {
	if l.client == nil {
		return nil, errors.New("metadata search client is unavailable")
	}
	value, err := l.client.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	if value == nil {
		return nil, errors.New("metadata search returned a nil object")
	}
	return searchMetadataObject(value), nil
}

func (l metadataSearchLister) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*unstructured.UnstructuredList, error) {
	if l.client == nil {
		return nil, errors.New("metadata search client is unavailable")
	}
	page, err := l.client.List(ctx, options)
	if err != nil {
		return nil, err
	}
	if page == nil {
		return nil, errors.New("metadata search returned nil page")
	}
	result := &unstructured.UnstructuredList{
		Items: make([]unstructured.Unstructured, len(page.Items)),
	}
	result.SetResourceVersion(page.GetResourceVersion())
	result.SetContinue(page.GetContinue())
	result.SetRemainingItemCount(page.GetRemainingItemCount())
	for index := range page.Items {
		result.Items[index] = *searchMetadataObject(&page.Items[index])
	}
	return result, nil
}

func searchMetadataObject(value metav1.Object) *unstructured.Unstructured {
	result := &unstructured.Unstructured{}
	if value == nil {
		return result
	}
	result.SetName(value.GetName())
	result.SetNamespace(value.GetNamespace())
	result.SetUID(value.GetUID())
	result.SetResourceVersion(value.GetResourceVersion())
	return result
}
