package logs

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

func TestCronJobResolutionUsesMetadataOwnerScanAndOneNarrowPodList(t *testing.T) {
	t.Parallel()
	controller := true
	cronJob := batchv1.CronJob{
		TypeMeta:   metav1.TypeMeta{APIVersion: "batch/v1", Kind: "CronJob"},
		ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "backup", UID: "cron-uid"},
	}
	jobs := []batchv1.Job{
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
			ObjectMeta: metav1.ObjectMeta{
				Namespace: "team", Name: "backup-1", UID: "job-1",
				OwnerReferences: []metav1.OwnerReference{{UID: cronJob.UID, Controller: &controller}},
			},
			Spec: batchv1.JobSpec{Selector: labelSelector(batchv1.ControllerUidLabel, "job-1")},
		},
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
			ObjectMeta: metav1.ObjectMeta{
				Namespace: "team", Name: "backup-2", UID: "job-2",
				OwnerReferences: []metav1.OwnerReference{{UID: cronJob.UID, Controller: &controller}},
			},
			Spec: batchv1.JobSpec{Selector: labelSelector(batchv1.ControllerUidLabel, "job-2")},
		},
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
			ObjectMeta: metav1.ObjectMeta{
				Namespace: "team", Name: "unrelated", UID: "job-other",
				OwnerReferences: []metav1.OwnerReference{{UID: "other-cron", Controller: &controller}},
			},
			Spec: batchv1.JobSpec{Selector: labelSelector(batchv1.ControllerUidLabel, "job-other")},
		},
	}
	pods := []corev1.Pod{
		*podForController("backup-1-pod", "pod-1", "job-1", map[string]string{
			batchv1.ControllerUidLabel: "job-1",
		}, "main"),
		*podForController("backup-2-pod", "pod-2", "job-2", map[string]string{
			batchv1.ControllerUidLabel: "job-2",
		}, "worker"),
		*podForController("unrelated-pod", "pod-other", "job-other", map[string]string{
			batchv1.ControllerUidLabel: "job-other",
		}, "other"),
	}

	type observedRequest struct {
		method        string
		path          string
		accept        string
		labelSelector string
		fieldSelector string
	}
	var requestsMu sync.Mutex
	var requests []observedRequest
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestsMu.Lock()
		requests = append(requests, observedRequest{
			method: request.Method, path: request.URL.Path, accept: request.Header.Get("Accept"),
			labelSelector: request.URL.Query().Get("labelSelector"),
			fieldSelector: request.URL.Query().Get("fieldSelector"),
		})
		requestsMu.Unlock()

		switch request.URL.Path {
		case "/apis/batch/v1/namespaces/team/cronjobs/backup":
			writeResolutionJSON(t, writer, http.StatusOK, cronJob)
		case "/apis/batch/v1/namespaces/team/jobs":
			if strings.Contains(request.Header.Get("Accept"), "as=PartialObjectMetadataList") {
				items := make([]metav1.PartialObjectMetadata, 0, len(jobs))
				for index := range jobs {
					items = append(items, metav1.PartialObjectMetadata{
						TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
						ObjectMeta: metav1.ObjectMeta{
							Namespace: jobs[index].Namespace, Name: jobs[index].Name, UID: jobs[index].UID,
							OwnerReferences: jobs[index].OwnerReferences,
						},
					})
				}
				writeResolutionJSON(t, writer, http.StatusOK, metav1.PartialObjectMetadataList{
					TypeMeta: metav1.TypeMeta{APIVersion: "meta.k8s.io/v1", Kind: "PartialObjectMetadataList"},
					Items:    items,
				})
				return
			}
			switch request.URL.Query().Get("fieldSelector") {
			case "metadata.name=backup-1":
				writeResolutionJSON(t, writer, http.StatusOK, batchv1.JobList{
					TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "JobList"}, Items: jobs[:1],
				})
			case "metadata.name=backup-2":
				writeResolutionJSON(t, writer, http.StatusOK, batchv1.JobList{
					TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "JobList"}, Items: jobs[1:2],
				})
			default:
				t.Errorf("unexpected full Job LIST field selector = %q", request.URL.Query().Get("fieldSelector"))
				http.NotFound(writer, request)
			}
		case "/api/v1/namespaces/team/pods":
			writeResolutionJSON(t, writer, http.StatusOK, corev1.PodList{
				TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "PodList"}, Items: pods,
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	clients := newHTTPResolutionClients(t, server.URL)

	isWorkload, err := clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "batch", Version: "v1", Resource: "cronjobs",
		Namespace: "team", Name: "backup", UID: "cron-uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !isWorkload || len(clients.pods) != 2 || clients.pods["pod-1"].Identity.Name != "backup-1-pod" ||
		clients.pods["pod-2"].Identity.Name != "backup-2-pod" {
		t.Fatalf("resolution = workload %v, pods %#v", isWorkload, clients.pods)
	}

	requestsMu.Lock()
	observed := append([]observedRequest(nil), requests...)
	requestsMu.Unlock()
	if len(observed) != 5 {
		t.Fatalf("Kubernetes requests = %#v; want CronJob GET, metadata Job LIST, two exact Job LISTs, one Pod LIST", observed)
	}
	var podLists, metadataLists, exactJobLists int
	for _, request := range observed {
		switch request.path {
		case "/apis/batch/v1/namespaces/team/jobs":
			if strings.Contains(request.accept, "as=PartialObjectMetadataList") {
				metadataLists++
				if request.labelSelector != "" || request.fieldSelector != "" {
					t.Fatalf("owner-reference metadata scan selectors = %q / %q; want empty", request.labelSelector, request.fieldSelector)
				}
			} else {
				exactJobLists++
				if request.fieldSelector != "metadata.name=backup-1" && request.fieldSelector != "metadata.name=backup-2" {
					t.Fatalf("full Job LIST field selector = %q; want one exact owned name", request.fieldSelector)
				}
			}
		case "/api/v1/namespaces/team/pods":
			podLists++
			selector, parseErr := labels.Parse(request.labelSelector)
			if parseErr != nil {
				t.Fatalf("parse Pod selector %q: %v", request.labelSelector, parseErr)
			}
			if selector.Empty() || !selector.Matches(labels.Set{batchv1.ControllerUidLabel: "job-1"}) ||
				!selector.Matches(labels.Set{batchv1.ControllerUidLabel: "job-2"}) ||
				selector.Matches(labels.Set{batchv1.ControllerUidLabel: "job-other"}) {
				t.Fatalf("Pod selector = %q; want exactly both owned Job UIDs", request.labelSelector)
			}
		}
	}
	if metadataLists != 1 || exactJobLists != 2 || podLists != 1 {
		t.Fatalf("metadata Job / exact Job / Pod LISTs = %d / %d / %d; want 1 / 2 / 1", metadataLists, exactJobLists, podLists)
	}
}

func TestCronJobMetadataListFailureDoesNotBroadenToPods(t *testing.T) {
	t.Parallel()
	var podRequests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/apis/batch/v1/namespaces/team/cronjobs/backup":
			writeResolutionJSON(t, writer, http.StatusOK, batchv1.CronJob{
				TypeMeta:   metav1.TypeMeta{APIVersion: "batch/v1", Kind: "CronJob"},
				ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "backup", UID: "cron-uid"},
			})
		case "/apis/batch/v1/namespaces/team/jobs":
			writeResolutionJSON(t, writer, http.StatusForbidden, metav1.Status{
				TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"},
				Status:   metav1.StatusFailure, Reason: metav1.StatusReasonForbidden, Code: http.StatusForbidden,
				Message: "Jobs metadata is forbidden",
			})
		case "/api/v1/namespaces/team/pods":
			podRequests++
			http.Error(writer, "unexpected broad Pod fallback", http.StatusInternalServerError)
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	clients := newHTTPResolutionClients(t, server.URL)

	_, err := clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "batch", Version: "v1", Resource: "cronjobs",
		Namespace: "team", Name: "backup", UID: "cron-uid",
	})
	if !apierrors.IsForbidden(err) {
		t.Fatalf("resolution error = %v; want Forbidden", err)
	}
	if podRequests != 0 {
		t.Fatalf("Pod requests after permanent metadata error = %d; want 0", podRequests)
	}
}

func newHTTPResolutionClients(t *testing.T, host string) *sourceResolutionClients {
	t.Helper()
	config := &rest.Config{Host: host}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	coreClient, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	return &sourceResolutionClients{
		sessionID: "session", dynamic: dynamicClient, metadata: metadataClient, core: coreClient,
		maxPods: DefaultMaxResolvedPods, pods: make(map[types.UID]PodInventory),
	}
}

func writeResolutionJSON(t *testing.T, writer http.ResponseWriter, status int, value any) {
	t.Helper()
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		t.Errorf("encode response: %v", err)
	}
}
