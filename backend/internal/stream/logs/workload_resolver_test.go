package logs

import (
	"context"
	"errors"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	kubernetesfake "k8s.io/client-go/kubernetes/fake"
)

func TestDeploymentResolutionRequiresEveryOwnerUIDHop(t *testing.T) {
	t.Parallel()
	controller := true
	deployment := &appsv1.Deployment{
		TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "web", UID: "deployment-uid"},
		Spec:       appsv1.DeploymentSpec{Selector: labelSelector("app", "web")},
	}
	ownedReplicaSet := &appsv1.ReplicaSet{
		TypeMeta: metav1.TypeMeta{APIVersion: "apps/v1", Kind: "ReplicaSet"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team", Name: "web-good", UID: "rs-good", Labels: map[string]string{"app": "web"},
			OwnerReferences: []metav1.OwnerReference{{UID: deployment.UID, Controller: &controller}},
		},
		Spec: appsv1.ReplicaSetSpec{Selector: labelSelector("app", "web")},
	}
	unrelatedReplicaSet := ownedReplicaSet.DeepCopy()
	unrelatedReplicaSet.Name = "web-other"
	unrelatedReplicaSet.UID = "rs-other"
	unrelatedReplicaSet.OwnerReferences[0].UID = "other-deployment"
	goodPod := podForController("web-good-1", "pod-good", ownedReplicaSet.UID, map[string]string{"app": "web"}, "app", "sidecar")
	wrongOwnerPod := podForController("web-wrong-1", "pod-wrong", unrelatedReplicaSet.UID, map[string]string{"app": "web"}, "app")
	directPod := podForController("web-direct-1", "pod-direct", deployment.UID, map[string]string{"app": "web"}, "app")

	clients := resolutionTestClients(
		t,
		[]runtime.Object{deployment, ownedReplicaSet, unrelatedReplicaSet},
		goodPod, wrongOwnerPod, directPod,
	)
	isWorkload, err := clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "team", Name: "web", UID: "deployment-uid",
	})
	if err != nil {
		t.Fatalf("resolveOne: %v", err)
	}
	if !isWorkload || len(clients.pods) != 1 {
		t.Fatalf("resolved workload/pods = %v/%#v", isWorkload, clients.pods)
	}
	inventory := clients.pods[goodPod.UID]
	if inventory.Identity.SessionID != "session" || inventory.Identity.UID != "pod-good" ||
		len(inventory.Containers) != 2 || inventory.Containers[0] != "app" || inventory.Containers[1] != "sidecar" {
		t.Fatalf("Pod inventory = %#v", inventory)
	}
}

func TestCronJobResolutionRequiresCronJobToJobToPodOwnerUIDs(t *testing.T) {
	t.Parallel()
	controller := true
	cronJob := &batchv1.CronJob{
		TypeMeta:   metav1.TypeMeta{APIVersion: "batch/v1", Kind: "CronJob"},
		ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "backup", UID: "cron-uid"},
	}
	ownedJob := &batchv1.Job{
		TypeMeta: metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team", Name: "backup-1", UID: "job-good",
			OwnerReferences: []metav1.OwnerReference{{UID: cronJob.UID, Controller: &controller}},
		},
		// Exercise the safe bounded owner-UID fallback used for API-defaulted
		// Jobs whose selector is absent from a synthetic/fake representation.
		Spec: batchv1.JobSpec{Selector: nil},
	}
	unrelatedJob := ownedJob.DeepCopy()
	unrelatedJob.Name = "other-1"
	unrelatedJob.UID = "job-other"
	unrelatedJob.OwnerReferences[0].UID = "other-cron"
	goodPod := podForController("backup-pod", "pod-good", ownedJob.UID, map[string]string{"job": "backup"}, "backup")
	wrongPod := podForController("other-pod", "pod-other", unrelatedJob.UID, map[string]string{"job": "backup"}, "backup")

	clients := resolutionTestClients(t, []runtime.Object{cronJob, ownedJob, unrelatedJob}, goodPod, wrongPod)
	isWorkload, err := clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "batch", Version: "v1", Resource: "cronjobs",
		Namespace: "team", Name: "backup", UID: "cron-uid",
	})
	if err != nil {
		t.Fatalf("resolveOne: %v", err)
	}
	if !isWorkload || len(clients.pods) != 1 || clients.pods[goodPod.UID].Identity.Name != "backup-pod" {
		t.Fatalf("CronJob resolution = workload %v, pods %#v", isWorkload, clients.pods)
	}
}

func TestDirectWorkloadControllersResolveOnlyOwnedPods(t *testing.T) {
	t.Parallel()
	selector := labelSelector("component", "worker")
	tests := []struct {
		name       string
		group      string
		resource   string
		controller runtime.Object
	}{
		{
			name: "ReplicaSet", group: "apps", resource: "replicasets",
			controller: &appsv1.ReplicaSet{
				TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "ReplicaSet"},
				ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "worker", UID: "controller-uid"},
				Spec:       appsv1.ReplicaSetSpec{Selector: selector},
			},
		},
		{
			name: "StatefulSet", group: "apps", resource: "statefulsets",
			controller: &appsv1.StatefulSet{
				TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "StatefulSet"},
				ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "worker", UID: "controller-uid"},
				Spec:       appsv1.StatefulSetSpec{Selector: selector},
			},
		},
		{
			name: "DaemonSet", group: "apps", resource: "daemonsets",
			controller: &appsv1.DaemonSet{
				TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "DaemonSet"},
				ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "worker", UID: "controller-uid"},
				Spec:       appsv1.DaemonSetSpec{Selector: selector},
			},
		},
		{
			name: "Job", group: "batch", resource: "jobs",
			controller: &batchv1.Job{
				TypeMeta:   metav1.TypeMeta{APIVersion: "batch/v1", Kind: "Job"},
				ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "worker", UID: "controller-uid"},
				Spec:       batchv1.JobSpec{Selector: selector},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			owned := podForController(
				"worker-1", "pod-owned", "controller-uid",
				map[string]string{"component": "worker"}, "worker",
			)
			wrong := podForController(
				"worker-wrong", "pod-wrong", "different-controller",
				map[string]string{"component": "worker"}, "worker",
			)
			clients := resolutionTestClients(t, []runtime.Object{test.controller}, owned, wrong)
			isWorkload, err := clients.resolveOne(context.Background(), Identity{
				SessionID: "session", Group: test.group, Version: "v1", Resource: test.resource,
				Namespace: "team", Name: "worker", UID: "controller-uid",
			})
			if err != nil {
				t.Fatal(err)
			}
			if !isWorkload || len(clients.pods) != 1 || clients.pods[owned.UID].Identity.UID != "pod-owned" {
				t.Fatalf("resolution = workload %v pods %#v", isWorkload, clients.pods)
			}
		})
	}
}

func TestResolutionRejectsReplacementAndDeduplicatesMixedSelection(t *testing.T) {
	t.Parallel()
	replicaSet := &appsv1.ReplicaSet{
		TypeMeta:   metav1.TypeMeta{APIVersion: "apps/v1", Kind: "ReplicaSet"},
		ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "api", UID: "rs-current"},
		Spec:       appsv1.ReplicaSetSpec{Selector: labelSelector("app", "api")},
	}
	pod := podForController("api-1", "pod-uid", replicaSet.UID, map[string]string{"app": "api"}, "app")
	second := podForController("api-2", "pod-2", replicaSet.UID, map[string]string{"app": "api"}, "app")
	clients := resolutionTestClients(t, []runtime.Object{replicaSet}, pod, second)
	clients.maxPods = 2

	_, err := clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "replicasets",
		Namespace: "team", Name: "api", UID: "stale-rs",
	})
	var mismatch *ResolutionUIDMismatchError
	if !errors.As(err, &mismatch) || len(clients.pods) != 0 {
		t.Fatalf("replacement error/pods = %v/%#v", err, clients.pods)
	}

	clients.maxPods = 1
	_, err = clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods",
		Namespace: "team", Name: pod.Name, UID: string(pod.UID),
	})
	if err != nil {
		t.Fatal(err)
	}
	// The same Pod reached through a direct selection and controller path is
	// one source. The second distinct owned Pod makes the bounded snapshot fail
	// instead of silently truncating.
	_, err = clients.resolveOne(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "replicasets",
		Namespace: "team", Name: "api", UID: "rs-current",
	})
	var tooMany *TooManyResolvedPodsError
	if !errors.As(err, &tooMany) || tooMany.Limit != 1 || len(clients.pods) != 1 {
		t.Fatalf("bounded mixed resolution = %v, pods %#v", err, clients.pods)
	}
}

func TestResolutionAPICallBudgetIsAggregateAcrossSelectedIdentities(t *testing.T) {
	t.Parallel()
	first := podForController("first", "first-uid", "owner", nil, "app")
	second := podForController("second", "second-uid", "owner", nil, "app")
	clients := resolutionTestClients(t, nil, first, second)
	clients.apiCalls = defaultMaxResolutionCalls - 1

	if _, err := clients.resolveOne(context.Background(), directPodIdentity(first)); err != nil {
		t.Fatalf("identity consuming final API call: %v", err)
	}
	_, err := clients.resolveOne(context.Background(), directPodIdentity(second))
	var limit *ResolutionRequestLimitError
	if !errors.As(err, &limit) || limit.Limit != defaultMaxResolutionCalls {
		t.Fatalf("next identity error = %v", err)
	}
}

func TestResolutionObjectBudgetIsAggregateAcrossSelectedIdentities(t *testing.T) {
	t.Parallel()
	first := podForController("first", "first-uid", "owner", nil, "app")
	second := podForController("second", "second-uid", "owner", nil, "app")
	clients := resolutionTestClients(t, nil, first, second)
	clients.objectsExamined = defaultMaxResolutionObjects - 1

	if _, err := clients.resolveOne(context.Background(), directPodIdentity(first)); err != nil {
		t.Fatalf("identity consuming final object slot: %v", err)
	}
	_, err := clients.resolveOne(context.Background(), directPodIdentity(second))
	var limit *ResolutionScanLimitError
	if !errors.As(err, &limit) || limit.Limit != defaultMaxResolutionObjects || limit.Resource != "Pods" {
		t.Fatalf("next identity error = %v", err)
	}
}

func resolutionTestClients(
	t *testing.T,
	controllers []runtime.Object,
	pods ...*corev1.Pod,
) *sourceResolutionClients {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := appsv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := batchv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	return &sourceResolutionClients{
		sessionID: "session",
		core:      kubernetesfake.NewSimpleClientset(podRuntimeObjects(pods)...).CoreV1(),
		dynamic:   dynamicfake.NewSimpleDynamicClient(scheme, controllers...),
		maxPods:   DefaultMaxResolvedPods,
		pods:      make(map[types.UID]PodInventory),
	}
}

func podRuntimeObjects(values []*corev1.Pod) []runtime.Object {
	result := make([]runtime.Object, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	return result
}

func labelSelector(key, value string) *metav1.LabelSelector {
	return &metav1.LabelSelector{MatchLabels: map[string]string{key: value}}
}

func directPodIdentity(pod *corev1.Pod) Identity {
	return Identity{
		SessionID: "session", Version: "v1", Resource: "pods",
		Namespace: pod.Namespace, Name: pod.Name, UID: string(pod.UID),
	}
}

func podForController(
	name string,
	uid types.UID,
	ownerUID types.UID,
	labels map[string]string,
	containers ...string,
) *corev1.Pod {
	controller := true
	values := make([]corev1.Container, 0, len(containers))
	for _, name := range containers {
		values = append(values, corev1.Container{
			Name:  name,
			Image: "example.invalid/test",
		})
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team", Name: name, UID: uid, Labels: labels,
			OwnerReferences: []metav1.OwnerReference{{UID: ownerUID, Controller: &controller}},
		},
		Spec: corev1.PodSpec{Containers: values},
	}
}
