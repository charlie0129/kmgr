package object

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

type MutationType uint8

const (
	MutationSet MutationType = iota + 1
	MutationDelete
	MutationRename
)

type DataMutation struct {
	Type                MutationType
	Key                 string
	NewKey              string
	Kind                DataKind
	Value               []byte
	ExpectedContentHash []byte
}

type DataConflictError struct {
	Key          string
	ExpectedHash []byte
	CurrentHash  []byte
	Missing      bool
}

func (e *DataConflictError) Error() string {
	if e.Missing {
		return fmt.Sprintf("data key %q no longer exists", e.Key)
	}
	return fmt.Sprintf("data key %q changed since it was loaded", e.Key)
}

type ResourceVersionConflictError struct {
	Expected string
	Current  string
}

func (e *ResourceVersionConflictError) Error() string {
	return fmt.Sprintf("resource version changed from %q to %q", e.Expected, e.Current)
}

// UpdateData performs a fresh GET, validates UID/resourceVersion and every
// per-key content hash, then updates with Kubernetes optimistic concurrency.
// It never constructs an update from a stale whole-object copy.
func (r *Reader) UpdateData(
	ctx context.Context,
	identity Identity,
	expectedResourceVersion string,
	mutations []DataMutation,
) (Data, error) {
	if len(mutations) == 0 {
		return Data{}, errors.New("at least one data mutation is required")
	}
	value, err := r.Get(ctx, identity)
	if err != nil {
		return Data{}, err
	}
	if expectedResourceVersion == "" || value.GetResourceVersion() != expectedResourceVersion {
		return Data{}, &ResourceVersionConflictError{Expected: expectedResourceVersion, Current: value.GetResourceVersion()}
	}

	secret := identity.Group == "" && identity.Version == "v1" && identity.Resource == "secrets"
	configMap := identity.Group == "" && identity.Version == "v1" && identity.Resource == "configmaps"
	if !secret && !configMap {
		return Data{}, ErrUnsupportedDataObject
	}
	current, err := entriesByKey(value.Object, secret)
	if err != nil {
		return Data{}, err
	}
	if err := validateMutations(current, mutations); err != nil {
		return Data{}, err
	}
	for _, mutation := range mutations {
		switch mutation.Type {
		case MutationSet:
			current[mutation.Key] = newDataEntry(mutation.Key, mutation.Kind, mutation.Value)
		case MutationDelete:
			delete(current, mutation.Key)
		case MutationRename:
			entry := current[mutation.Key]
			delete(current, mutation.Key)
			entry.Key = mutation.NewKey
			current[mutation.NewKey] = entry
		}
	}
	if err := writeEntries(value, current, secret); err != nil {
		return Data{}, err
	}
	resource, err := r.resolver.Resource(identity.SessionID, identity.GVR(), identity.Namespace)
	if err != nil {
		return Data{}, err
	}
	updated, err := resource.Update(ctx, value, metav1.UpdateOptions{FieldManager: "kmgr"})
	if err != nil {
		return Data{}, err
	}
	entries, err := entriesByKey(updated.Object, secret)
	if err != nil {
		return Data{}, err
	}
	return Data{
		Identity: identity, ResourceVersion: updated.GetResourceVersion(), Secret: secret,
		Entries: sortedDataEntries(entries),
	}, nil
}

func entriesByKey(object map[string]any, secret bool) (map[string]DataEntry, error) {
	var entries []DataEntry
	var err error
	if secret {
		entries, err = secretEntries(object)
	} else {
		entries, err = configMapEntries(object)
	}
	if err != nil {
		return nil, err
	}
	result := make(map[string]DataEntry, len(entries))
	for _, entry := range entries {
		result[entry.Key] = entry
	}
	return result, nil
}

func validateMutations(current map[string]DataEntry, mutations []DataMutation) error {
	prospective := make(map[string]struct{}, len(current))
	for key := range current {
		prospective[key] = struct{}{}
	}
	for index, mutation := range mutations {
		if err := validateDataKey(mutation.Key); err != nil {
			return fmt.Errorf("mutation %d: %w", index, err)
		}
		entry, exists := current[mutation.Key]
		if len(mutation.ExpectedContentHash) != 0 {
			if !exists {
				return &DataConflictError{Key: mutation.Key, ExpectedHash: slices.Clone(mutation.ExpectedContentHash), Missing: true}
			}
			if !slices.Equal(mutation.ExpectedContentHash, entry.ContentHash[:]) {
				return &DataConflictError{
					Key: mutation.Key, ExpectedHash: slices.Clone(mutation.ExpectedContentHash),
					CurrentHash: slices.Clone(entry.ContentHash[:]),
				}
			}
		}
		switch mutation.Type {
		case MutationSet:
			if mutation.Kind != DataText && mutation.Kind != DataBinary {
				return fmt.Errorf("mutation %d has invalid data kind", index)
			}
			prospective[mutation.Key] = struct{}{}
		case MutationDelete:
			if !exists {
				return fmt.Errorf("mutation %d deletes unknown key %q", index, mutation.Key)
			}
			delete(prospective, mutation.Key)
		case MutationRename:
			if !exists {
				return fmt.Errorf("mutation %d renames unknown key %q", index, mutation.Key)
			}
			if err := validateDataKey(mutation.NewKey); err != nil {
				return fmt.Errorf("mutation %d: %w", index, err)
			}
			if _, duplicate := prospective[mutation.NewKey]; duplicate && mutation.NewKey != mutation.Key {
				return fmt.Errorf("mutation %d would overwrite existing key %q", index, mutation.NewKey)
			}
			delete(prospective, mutation.Key)
			prospective[mutation.NewKey] = struct{}{}
		default:
			return fmt.Errorf("mutation %d has invalid type", index)
		}
	}
	return nil
}

func validateDataKey(key string) error {
	if key == "" {
		return errors.New("data key must not be empty")
	}
	if len(key) > 253 {
		return fmt.Errorf("data key %q exceeds 253 bytes", key)
	}
	for _, character := range key {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || strings.ContainsRune("-_.", character) {
			continue
		}
		return fmt.Errorf("data key %q contains invalid character %q", key, character)
	}
	return nil
}

func writeEntries(object *unstructured.Unstructured, entries map[string]DataEntry, secret bool) error {
	if secret {
		data := make(map[string]any, len(entries))
		for key, entry := range entries {
			data[key] = base64.StdEncoding.EncodeToString(entry.Value)
		}
		if err := unstructured.SetNestedMap(object.Object, data, "data"); err != nil {
			return fmt.Errorf("write Secret data: %w", err)
		}
		delete(object.Object, "stringData")
		return nil
	}
	text := make(map[string]any)
	binary := make(map[string]any)
	for key, entry := range entries {
		if entry.Kind == DataText {
			text[key] = string(entry.Value)
		} else {
			binary[key] = base64.StdEncoding.EncodeToString(entry.Value)
		}
	}
	if err := unstructured.SetNestedMap(object.Object, text, "data"); err != nil {
		return fmt.Errorf("write ConfigMap data: %w", err)
	}
	if err := unstructured.SetNestedMap(object.Object, binary, "binaryData"); err != nil {
		return fmt.Errorf("write ConfigMap binaryData: %w", err)
	}
	return nil
}
