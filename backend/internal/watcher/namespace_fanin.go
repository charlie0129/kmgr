package watcher

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sync"
	"sync/atomic"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/apioperation"
)

const (
	namespaceCheckpointPrefix   = "kmgr-ns-rv-v1."
	namespaceContinuationPrefix = "kmgr-ns-page-v1."
)

// NamespaceStream is one exact namespaced LIST/WATCH endpoint. NamespaceFanIn
// keeps streams separate at the API server while presenting one logical
// collection to Pipeline.
type NamespaceStream struct {
	Namespace string
	Client    ListerWatcher
}

// NewNamespaceFanIn returns one ListerWatcher over two or more exact namespace
// endpoints. Streams are canonicalized by namespace so caller ordering cannot
// change pagination, checkpoints, or cache behavior. If every child supports
// Table content negotiation, the returned client preserves that representation
// and merges Table schemas and cells as well.
func NewNamespaceFanIn(streams []NamespaceStream) (ListerWatcher, error) {
	if len(streams) < 2 {
		return nil, errors.New("namespace fan-in requires at least two streams")
	}
	canonical := append([]NamespaceStream(nil), streams...)
	slices.SortFunc(canonical, func(left, right NamespaceStream) int {
		if left.Namespace < right.Namespace {
			return -1
		}
		if left.Namespace > right.Namespace {
			return 1
		}
		return 0
	})
	for index, stream := range canonical {
		if stream.Namespace == "" {
			return nil, fmt.Errorf("namespace fan-in stream %d has an empty namespace", index)
		}
		if stream.Client == nil {
			return nil, fmt.Errorf("namespace fan-in stream %q has a nil client", stream.Namespace)
		}
		if index != 0 && canonical[index-1].Namespace == stream.Namespace {
			return nil, fmt.Errorf("namespace fan-in repeats namespace %q", stream.Namespace)
		}
	}

	base := &namespaceFanIn{streams: canonical}
	tableStreams := make([]namespaceTableStream, len(canonical))
	for index, stream := range canonical {
		client, ok := stream.Client.(TableListerWatcher)
		if !ok {
			return base, nil
		}
		tableStreams[index] = namespaceTableStream{namespace: stream.Namespace, client: client}
	}
	return &namespaceTableFanIn{namespaceFanIn: base, streams: tableStreams}, nil
}

type namespaceFanIn struct {
	streams []NamespaceStream
}

// SupportsWatchListSemantics is deliberately false. A WatchList has no single
// server-side collection revision spanning exact namespace endpoints; the
// proven paginated LIST plus vector-resumed WATCH path below supplies the same
// consistency without broadening the request.
func (*namespaceFanIn) SupportsWatchListSemantics() bool { return false }

func (c *namespaceFanIn) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*unstructured.UnstructuredList, error) {
	state, err := c.listState(options.Continue)
	if err != nil {
		return nil, err
	}
	type result struct {
		page *unstructured.UnstructuredList
		err  error
	}
	results := make([]result, len(c.streams))
	var wait sync.WaitGroup
	for index, stream := range c.streams {
		if state.Streams[index].Done {
			continue
		}
		wait.Add(1)
		go func(index int, stream NamespaceStream) {
			defer wait.Done()
			childOptions := namespaceChildListOptions(options, state.Streams[index].Continue)
			results[index].page, results[index].err = stream.Client.List(ctx, childOptions)
		}(index, stream)
	}
	wait.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	items := make([]unstructured.Unstructured, 0)
	seenUIDs := make(map[types.UID]string)
	for index, stream := range c.streams {
		if state.Streams[index].Done {
			continue
		}
		page, err := results[index].page, results[index].err
		if err != nil {
			return nil, fmt.Errorf("list namespace %q: %w", stream.Namespace, err)
		}
		if page == nil {
			return nil, fmt.Errorf("list namespace %q: server returned a nil list", stream.Namespace)
		}
		if err := validateNamespacePage(
			stream.Namespace,
			page.GetResourceVersion(),
			state.Streams[index],
			unstructuredListObjects(page),
			seenUIDs,
		); err != nil {
			return nil, err
		}
		if state.Streams[index].ResourceVersion == "" {
			state.Streams[index].ResourceVersion = page.GetResourceVersion()
		}
		state.Streams[index].Continue = page.GetContinue()
		state.Streams[index].Done = page.GetContinue() == ""
		items = append(items, page.Items...)
	}

	checkpoint, err := encodeNamespaceCheckpoint(state.Streams)
	if err != nil {
		return nil, err
	}
	continuation, err := encodeNamespaceContinuation(state)
	if err != nil {
		return nil, err
	}
	response := &unstructured.UnstructuredList{Items: items}
	response.SetResourceVersion(checkpoint)
	response.SetContinue(continuation)
	return response, nil
}

func (c *namespaceFanIn) Watch(
	ctx context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	revisions, err := decodeNamespaceCheckpoint(options.ResourceVersion, c.namespaces())
	if err != nil {
		return nil, err
	}
	return openNamespaceWatch(ctx, c.streams, revisions, options, func(
		ctx context.Context,
		stream NamespaceStream,
		options metav1.ListOptions,
	) (watch.Interface, error) {
		return stream.Client.Watch(ctx, options)
	})
}

func (c *namespaceFanIn) namespaces() []string {
	result := make([]string, len(c.streams))
	for index, stream := range c.streams {
		result[index] = stream.Namespace
	}
	return result
}

type namespaceTableStream struct {
	namespace string
	client    TableListerWatcher
}

type namespaceTableFanIn struct {
	*namespaceFanIn
	streams  []namespaceTableStream
	disabled atomic.Bool
}

func (c *namespaceTableFanIn) TableEnabled() bool {
	if c == nil || c.disabled.Load() {
		return false
	}
	for _, stream := range c.streams {
		if !stream.client.TableEnabled() {
			return false
		}
	}
	return true
}

func (c *namespaceTableFanIn) DisableTable() {
	if c == nil {
		return
	}
	c.disabled.Store(true)
	for _, stream := range c.streams {
		stream.client.DisableTable()
	}
}

func (c *namespaceTableFanIn) ListTable(
	ctx context.Context,
	options metav1.ListOptions,
) (*TableList, error) {
	if !c.TableEnabled() {
		return c.listFallback(ctx, options)
	}
	state, err := c.listState(options.Continue)
	if err != nil {
		return nil, err
	}
	type result struct {
		page *TableList
		err  error
	}
	results := make([]result, len(c.streams))
	var wait sync.WaitGroup
	for index, stream := range c.streams {
		if state.Streams[index].Done {
			continue
		}
		wait.Add(1)
		go func(index int, stream namespaceTableStream) {
			defer wait.Done()
			childOptions := namespaceChildListOptions(options, state.Streams[index].Continue)
			results[index].page, results[index].err = stream.client.ListTable(ctx, childOptions)
		}(index, stream)
	}
	wait.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	objects := make([]*unstructured.Unstructured, 0)
	cells := make(map[types.UID][]any)
	seenUIDs := make(map[types.UID]string)
	var columns []metav1.TableColumnDefinition
	needsFallback := false
	for index, stream := range c.streams {
		if state.Streams[index].Done {
			continue
		}
		page, err := results[index].page, results[index].err
		if err != nil {
			return nil, fmt.Errorf("list Table namespace %q: %w", stream.namespace, err)
		}
		if page == nil {
			return nil, fmt.Errorf("list Table namespace %q: server returned a nil list", stream.namespace)
		}
		if !page.ServerTable {
			needsFallback = true
			continue
		}
		if columns == nil {
			columns = append([]metav1.TableColumnDefinition(nil), page.Columns...)
		} else if !reflect.DeepEqual(columns, page.Columns) {
			needsFallback = true
			continue
		}
		if err := validateNamespacePage(
			stream.namespace,
			page.ResourceVersion,
			state.Streams[index],
			page.Objects,
			seenUIDs,
		); err != nil {
			return nil, err
		}
		for _, object := range page.Objects {
			uid := object.GetUID()
			row, exists := page.Cells[uid]
			if !exists {
				return nil, fmt.Errorf("Table namespace %q has no cells for UID %q", stream.namespace, uid)
			}
			cells[uid] = append([]any(nil), row...)
		}
		if state.Streams[index].ResourceVersion == "" {
			state.Streams[index].ResourceVersion = page.ResourceVersion
		}
		state.Streams[index].Continue = page.Continue
		state.Streams[index].Done = page.Continue == ""
		objects = append(objects, page.Objects...)
	}
	if needsFallback || !c.TableEnabled() {
		c.DisableTable()
		if options.Continue != "" {
			return nil, errors.New("namespace Table representation changed during pagination; retry ordinary LIST")
		}
		return c.listFallback(ctx, options)
	}

	checkpoint, err := encodeNamespaceCheckpoint(state.Streams)
	if err != nil {
		return nil, err
	}
	continuation, err := encodeNamespaceContinuation(state)
	if err != nil {
		return nil, err
	}
	return &TableList{
		ResourceVersion: checkpoint,
		Continue:        continuation,
		Objects:         objects,
		Columns:         columns,
		Cells:           cells,
		ServerTable:     true,
	}, nil
}

func (c *namespaceTableFanIn) WatchTable(
	ctx context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	if !c.TableEnabled() {
		return c.namespaceFanIn.Watch(ctx, options)
	}
	revisions, err := decodeNamespaceCheckpoint(options.ResourceVersion, c.namespaces())
	if err != nil {
		return nil, err
	}
	streams := make([]NamespaceStream, len(c.streams))
	for index, stream := range c.streams {
		streams[index] = NamespaceStream{Namespace: stream.namespace, Client: stream.client}
	}
	merged, err := openNamespaceWatch(ctx, streams, revisions, options, func(
		ctx context.Context,
		stream NamespaceStream,
		options metav1.ListOptions,
	) (watch.Interface, error) {
		return stream.Client.(TableListerWatcher).WatchTable(ctx, options)
	})
	if err != nil {
		return nil, err
	}
	if !c.TableEnabled() {
		// One child silently fell back to an ordinary watch. Relist all children
		// through the coherent raw representation so Pipeline publishes a Table
		// disable batch and cannot retain stale server cells beside raw events.
		merged.Stop()
		c.DisableTable()
		return nil, apierrors.NewResourceExpired("namespace Table watch fell back to raw objects")
	}
	return merged, nil
}

func (c *namespaceTableFanIn) listFallback(
	ctx context.Context,
	options metav1.ListOptions,
) (*TableList, error) {
	page, err := c.namespaceFanIn.List(ctx, options)
	if err != nil {
		return nil, err
	}
	objects := unstructuredListObjects(page)
	return &TableList{
		ResourceVersion: page.GetResourceVersion(),
		Continue:        page.GetContinue(),
		Objects:         objects,
	}, nil
}

type namespaceListState struct {
	Version int                    `json:"version"`
	Streams []namespaceStreamState `json:"streams"`
}

type namespaceStreamState struct {
	Namespace       string `json:"namespace"`
	ResourceVersion string `json:"resourceVersion"`
	Continue        string `json:"continue,omitempty"`
	Done            bool   `json:"done,omitempty"`
}

func (c *namespaceFanIn) listState(continuation string) (namespaceListState, error) {
	if continuation == "" {
		state := namespaceListState{Version: 1, Streams: make([]namespaceStreamState, len(c.streams))}
		for index, stream := range c.streams {
			state.Streams[index].Namespace = stream.Namespace
		}
		return state, nil
	}
	if len(continuation) <= len(namespaceContinuationPrefix) ||
		continuation[:len(namespaceContinuationPrefix)] != namespaceContinuationPrefix {
		return namespaceListState{}, errors.New("namespace fan-in received an invalid continuation token")
	}
	payload, err := base64.RawURLEncoding.DecodeString(continuation[len(namespaceContinuationPrefix):])
	if err != nil {
		return namespaceListState{}, errors.New("namespace fan-in received an invalid continuation token")
	}
	var state namespaceListState
	if err := json.Unmarshal(payload, &state); err != nil || state.Version != 1 || len(state.Streams) != len(c.streams) {
		return namespaceListState{}, errors.New("namespace fan-in received an invalid continuation token")
	}
	unfinished := false
	for index, stream := range c.streams {
		value := state.Streams[index]
		if value.Namespace != stream.Namespace || value.ResourceVersion == "" ||
			(value.Done && value.Continue != "") {
			return namespaceListState{}, errors.New("namespace fan-in continuation does not match this stream set")
		}
		unfinished = unfinished || !value.Done
	}
	if !unfinished {
		return namespaceListState{}, errors.New("namespace fan-in continuation is already complete")
	}
	return state, nil
}

func encodeNamespaceContinuation(state namespaceListState) (string, error) {
	for _, stream := range state.Streams {
		if !stream.Done {
			payload, err := json.Marshal(state)
			if err != nil {
				return "", fmt.Errorf("encode namespace continuation: %w", err)
			}
			return namespaceContinuationPrefix + base64.RawURLEncoding.EncodeToString(payload), nil
		}
	}
	return "", nil
}

func encodeNamespaceCheckpoint(streams []namespaceStreamState) (string, error) {
	checkpoint := namespaceListState{Version: 1, Streams: make([]namespaceStreamState, len(streams))}
	for index, stream := range streams {
		if stream.Namespace == "" || stream.ResourceVersion == "" {
			return "", errors.New("namespace fan-in cannot checkpoint an empty namespace or resourceVersion")
		}
		checkpoint.Streams[index] = namespaceStreamState{
			Namespace: stream.Namespace, ResourceVersion: stream.ResourceVersion, Done: true,
		}
	}
	payload, err := json.Marshal(checkpoint)
	if err != nil {
		return "", fmt.Errorf("encode namespace checkpoint: %w", err)
	}
	return namespaceCheckpointPrefix + base64.RawURLEncoding.EncodeToString(payload), nil
}

func decodeNamespaceCheckpoint(checkpoint string, namespaces []string) ([]string, error) {
	if checkpoint == "" {
		return make([]string, len(namespaces)), nil
	}
	if len(checkpoint) <= len(namespaceCheckpointPrefix) ||
		checkpoint[:len(namespaceCheckpointPrefix)] != namespaceCheckpointPrefix {
		return nil, errors.New("namespace fan-in received an invalid resourceVersion checkpoint")
	}
	payload, err := base64.RawURLEncoding.DecodeString(checkpoint[len(namespaceCheckpointPrefix):])
	if err != nil {
		return nil, errors.New("namespace fan-in received an invalid resourceVersion checkpoint")
	}
	var state namespaceListState
	if err := json.Unmarshal(payload, &state); err != nil || state.Version != 1 || len(state.Streams) != len(namespaces) {
		return nil, errors.New("namespace fan-in received an invalid resourceVersion checkpoint")
	}
	result := make([]string, len(namespaces))
	for index, namespace := range namespaces {
		stream := state.Streams[index]
		if stream.Namespace != namespace || stream.ResourceVersion == "" {
			return nil, errors.New("namespace fan-in resourceVersion does not match this stream set")
		}
		result[index] = stream.ResourceVersion
	}
	return result, nil
}

func namespaceChildListOptions(options metav1.ListOptions, continuation string) metav1.ListOptions {
	options.Continue = continuation
	if continuation != "" {
		options.ResourceVersion = ""
		options.ResourceVersionMatch = ""
	}
	return options
}

func validateNamespacePage(
	namespace string,
	resourceVersion string,
	state namespaceStreamState,
	objects []*unstructured.Unstructured,
	seenUIDs map[types.UID]string,
) error {
	if resourceVersion == "" {
		return fmt.Errorf("list namespace %q: page has no resourceVersion", namespace)
	}
	if state.ResourceVersion != "" && state.ResourceVersion != resourceVersion {
		return fmt.Errorf("list namespace %q: paginated resourceVersion changed", namespace)
	}
	for index, object := range objects {
		if object == nil || object.GetUID() == "" {
			return fmt.Errorf("list namespace %q: item %d has no UID", namespace, index)
		}
		if object.GetNamespace() != namespace {
			return fmt.Errorf(
				"list namespace %q: item %d belongs to namespace %q",
				namespace,
				index,
				object.GetNamespace(),
			)
		}
		if previous, duplicate := seenUIDs[object.GetUID()]; duplicate {
			return fmt.Errorf(
				"list namespace %q: UID %q was also returned by namespace %q",
				namespace,
				object.GetUID(),
				previous,
			)
		}
		seenUIDs[object.GetUID()] = namespace
	}
	return nil
}

func unstructuredListObjects(list *unstructured.UnstructuredList) []*unstructured.Unstructured {
	if list == nil {
		return nil
	}
	result := make([]*unstructured.Unstructured, len(list.Items))
	for index := range list.Items {
		result[index] = &list.Items[index]
	}
	return result
}

type namespaceWatchOpen func(
	context.Context,
	NamespaceStream,
	metav1.ListOptions,
) (watch.Interface, error)

func openNamespaceWatch(
	ctx context.Context,
	streams []NamespaceStream,
	revisions []string,
	options metav1.ListOptions,
	open namespaceWatchOpen,
) (watch.Interface, error) {
	if len(revisions) != len(streams) {
		return nil, errors.New("namespace fan-in checkpoint has the wrong stream count")
	}
	streamCtx, cancel := context.WithCancel(ctx)
	results := make([]namespaceWatchOpenResult, len(streams))
	var wait sync.WaitGroup
	for index, stream := range streams {
		wait.Add(1)
		go func(index int, stream NamespaceStream) {
			defer wait.Done()
			childOptions := options
			childOptions.ResourceVersion = revisions[index]
			childOptions.Continue = ""
			childContext, observer := apioperation.WithWatchErrorObserver(streamCtx)
			results[index].observer = observer
			results[index].stream, results[index].err = open(childContext, stream, childOptions)
		}(index, stream)
	}
	wait.Wait()
	if err := ctx.Err(); err != nil {
		cancel()
		stopNamespaceWatches(results)
		return nil, err
	}
	for index, result := range results {
		if result.err != nil {
			cancel()
			stopNamespaceWatches(results)
			return nil, fmt.Errorf("watch namespace %q: %w", streams[index].Namespace, result.err)
		}
		if result.stream == nil {
			cancel()
			stopNamespaceWatches(results)
			return nil, fmt.Errorf("watch namespace %q: server returned a nil watch", streams[index].Namespace)
		}
	}
	children := make([]watch.Interface, len(results))
	observers := make([]*apioperation.WatchErrorObserver, len(results))
	for index, result := range results {
		children[index] = result.stream
		observers[index] = result.observer
	}
	merged := &namespaceWatch{
		ctx:       streamCtx,
		cancel:    cancel,
		streams:   streams,
		children:  children,
		observers: observers,
		revisions: append([]string(nil), revisions...),
		result:    make(chan watch.Event),
	}
	go merged.run()
	return merged, nil
}

func stopNamespaceWatches(results []namespaceWatchOpenResult) {
	for _, result := range results {
		if stream := result.stream; stream != nil {
			stream.Stop()
		}
	}
}

type namespaceWatchOpenResult struct {
	stream   watch.Interface
	observer *apioperation.WatchErrorObserver
	err      error
}

type namespaceWatch struct {
	ctx       context.Context
	cancel    context.CancelFunc
	streams   []NamespaceStream
	children  []watch.Interface
	observers []*apioperation.WatchErrorObserver
	revisions []string
	result    chan watch.Event
	stopOnce  sync.Once
}

type namespacedWatchEvent struct {
	index int
	event watch.Event
	open  bool
}

func (w *namespaceWatch) Stop() {
	w.stopOnce.Do(func() {
		w.cancel()
		for _, child := range w.children {
			child.Stop()
		}
	})
}

func (w *namespaceWatch) ResultChan() <-chan watch.Event { return w.result }

func (w *namespaceWatch) run() {
	defer close(w.result)
	defer w.Stop()
	incoming := make(chan namespacedWatchEvent)
	var readers sync.WaitGroup
	for index, child := range w.children {
		readers.Add(1)
		go func(index int, child watch.Interface) {
			defer readers.Done()
			for {
				select {
				case <-w.ctx.Done():
					return
				case event, ok := <-child.ResultChan():
					select {
					case incoming <- namespacedWatchEvent{index: index, event: event, open: ok}:
					case <-w.ctx.Done():
						return
					}
					if !ok {
						return
					}
				}
			}
		}(index, child)
	}
	defer func() {
		w.Stop()
		readers.Wait()
	}()

	for {
		select {
		case <-w.ctx.Done():
			return
		case incomingEvent := <-incoming:
			if !incomingEvent.open {
				return
			}
			event := incomingEvent.event
			if event.Type == watch.Error && incomingEvent.index >= 0 &&
				incomingEvent.index < len(w.observers) {
				w.observers[incomingEvent.index].Observe(apierrors.FromObject(event.Object))
			}
			if event.Type != watch.Error {
				checkpointed, err := checkpointNamespaceEvent(
					w.streams,
					event,
					w.revisions,
					incomingEvent.index,
				)
				if err != nil {
					event = watch.Event{Type: watch.Error, Object: &metav1.Status{
						Status:  metav1.StatusFailure,
						Reason:  metav1.StatusReasonInternalError,
						Code:    500,
						Message: err.Error(),
					}}
				} else {
					event = checkpointed
				}
			}
			select {
			case w.result <- event:
			case <-w.ctx.Done():
				return
			}
			if event.Type == watch.Error {
				return
			}
		}
	}
}

// checkpointedWatchObject keeps the composite continuation point outside the
// Kubernetes object. Pipeline unwraps Object before storage, so columns,
// Details reuse, and optimistic operations continue seeing the native object
// resourceVersion.
type checkpointedWatchObject struct {
	Object     runtime.Object
	Checkpoint string
}

func (o *checkpointedWatchObject) GetObjectKind() schema.ObjectKind {
	if o == nil || o.Object == nil {
		return schema.EmptyObjectKind
	}
	return o.Object.GetObjectKind()
}

func (o *checkpointedWatchObject) DeepCopyObject() runtime.Object {
	if o == nil {
		return nil
	}
	copy := &checkpointedWatchObject{Checkpoint: o.Checkpoint}
	if o.Object != nil {
		copy.Object = o.Object.DeepCopyObject()
	}
	return copy
}

func checkpointNamespaceEvent(
	streams []NamespaceStream,
	event watch.Event,
	revisions []string,
	index int,
) (watch.Event, error) {
	if index < 0 || index >= len(streams) || len(revisions) != len(streams) {
		return watch.Event{}, errors.New("namespace watch event has an invalid stream index")
	}
	namespace := streams[index].Namespace
	if event.Object == nil {
		return watch.Event{}, fmt.Errorf("watch namespace %q returned a nil %s object", namespace, event.Type)
	}
	accessor, err := meta.Accessor(event.Object)
	if err != nil {
		return watch.Event{}, fmt.Errorf("read namespace %q %s event metadata: %w", namespace, event.Type, err)
	}
	nativeRevision := accessor.GetResourceVersion()
	if nativeRevision == "" {
		return watch.Event{}, fmt.Errorf("watch namespace %q returned %s without resourceVersion", namespace, event.Type)
	}
	if event.Type != watch.Bookmark {
		objectNamespace, err := namespaceEventObjectNamespace(event.Object)
		if err != nil {
			return watch.Event{}, fmt.Errorf("watch namespace %q: %w", namespace, err)
		}
		if objectNamespace != namespace {
			return watch.Event{}, fmt.Errorf(
				"watch namespace %q returned %s object from namespace %q",
				namespace,
				event.Type,
				objectNamespace,
			)
		}
	}
	revisions[index] = nativeRevision
	states := make([]namespaceStreamState, len(revisions))
	for streamIndex, revision := range revisions {
		if revision == "" {
			return watch.Event{}, fmt.Errorf(
				"watch namespace %q cannot advance an incomplete checkpoint",
				namespace,
			)
		}
		states[streamIndex] = namespaceStreamState{
			Namespace: streams[streamIndex].Namespace, ResourceVersion: revision, Done: true,
		}
	}
	checkpoint, err := encodeNamespaceCheckpoint(states)
	if err != nil {
		return watch.Event{}, err
	}
	return watch.Event{
		Type: event.Type,
		Object: &checkpointedWatchObject{
			Object: event.Object, Checkpoint: checkpoint,
		},
	}, nil
}

func namespaceEventObjectNamespace(object runtime.Object) (string, error) {
	if table, ok := object.(*metav1.Table); ok {
		if len(table.Rows) != 1 {
			return "", fmt.Errorf("Table watch event has %d rows; want 1", len(table.Rows))
		}
		value, err := decodeTableObject(&table.Rows[0])
		if err != nil {
			return "", fmt.Errorf("decode Table watch object: %w", err)
		}
		return value.GetNamespace(), nil
	}
	accessor, err := meta.Accessor(object)
	if err != nil {
		return "", err
	}
	return accessor.GetNamespace(), nil
}
