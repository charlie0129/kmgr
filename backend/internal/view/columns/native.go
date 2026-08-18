package columns

// NativeResource identifies the exact API resource for extractor validation.
// Version "*" in the registry matches every served version of that resource.
type NativeResource struct {
	Group    string
	Version  string
	Resource string
}

type NativeExtractorDefinition struct {
	Type      ResultType
	Resources []NativeResource
}

func nativeResources(group, version string, resources ...string) []NativeResource {
	result := make([]NativeResource, 0, len(resources))
	for _, resource := range resources {
		result = append(result, NativeResource{Group: group, Version: version, Resource: resource})
	}
	return result
}

func combineNativeResources(values ...[]NativeResource) []NativeResource {
	var result []NativeResource
	for _, value := range values {
		result = append(result, value...)
	}
	return result
}

var (
	nativePods        = nativeResources("", "v1", "pods")
	nativeNodes       = nativeResources("", "v1", "nodes")
	nativeApps        = nativeResources("apps", "v1", "deployments", "statefulsets", "daemonsets", "replicasets")
	nativeControllers = nativeResources("", "v1", "replicationcontrollers")
	nativeTemplates   = combineNativeResources(nativeApps, nativeControllers, nativeResources("batch", "v1", "jobs", "cronjobs"))
	nativeMetadata    = []NativeResource(nil) // nil means every resource.
)

// NativeExtractorDefinitions is the authoritative Go half of the native
// column contract. Every extractor reads only the row object. The metric
// extractors are kept separate because they may lazily use Metrics API, but
// they likewise never open a LIST/WATCH for another Kubernetes resource.
var NativeExtractorDefinitions = map[string]NativeExtractorDefinition{
	"namespace":       {Type: ResultString, Resources: nativeMetadata},
	"name":            {Type: ResultString, Resources: nativeMetadata},
	"kind":            {Type: ResultString, Resources: nativeMetadata},
	"labels":          {Type: ResultString, Resources: nativeMetadata},
	"age":             {Type: ResultDuration, Resources: nativeMetadata},
	"created":         {Type: ResultTimestamp, Resources: nativeMetadata},
	"resourceVersion": {Type: ResultString, Resources: nativeMetadata},

	"status": {Type: ResultString, Resources: combineNativeResources(
		nativePods, nativeNodes,
		nativeResources("", "v1", "namespaces", "persistentvolumes", "persistentvolumeclaims"),
		nativeResources("batch", "v1", "jobs"),
	)},
	"ready": {Type: ResultString, Resources: combineNativeResources(
		nativePods, nativeResources("apps", "v1", "deployments", "statefulsets"),
	)},
	"restarts":        {Type: ResultInteger, Resources: nativePods},
	"pod-ip":          {Type: ResultString, Resources: nativePods},
	"node":            {Type: ResultString, Resources: nativePods},
	"last-restart":    {Type: ResultTimestamp, Resources: nativePods},
	"service-account": {Type: ResultString, Resources: nativePods},
	"qos-class":       {Type: ResultString, Resources: nativePods},
	"readiness-gates": {Type: ResultString, Resources: nativePods},
	"nominated-node":  {Type: ResultString, Resources: nativePods},

	"roles":           {Type: ResultString, Resources: nativeNodes},
	"taints":          {Type: ResultInteger, Resources: nativeNodes},
	"internal-ip":     {Type: ResultString, Resources: nativeNodes},
	"external-ip":     {Type: ResultString, Resources: nativeNodes},
	"kubelet-version": {Type: ResultString, Resources: nativeNodes},
	"architecture":    {Type: ResultString, Resources: nativeNodes},
	"os-image":        {Type: ResultString, Resources: nativeNodes},
	"kernel-version":  {Type: ResultString, Resources: nativeNodes},

	"up-to-date": {Type: ResultInteger, Resources: nativeResources("apps", "v1", "deployments", "daemonsets")},
	"available":  {Type: ResultInteger, Resources: nativeResources("apps", "v1", "deployments", "daemonsets")},
	"desired": {Type: ResultInteger, Resources: combineNativeResources(
		nativeApps, nativeControllers,
	)},
	"current": {Type: ResultInteger, Resources: combineNativeResources(
		nativeResources("apps", "v1", "statefulsets", "daemonsets", "replicasets"), nativeControllers,
	)},
	"updated": {Type: ResultInteger, Resources: nativeResources("apps", "v1", "statefulsets")},
	"ready-count": {Type: ResultInteger, Resources: combineNativeResources(
		nativeResources("apps", "v1", "daemonsets", "replicasets"), nativeControllers,
		nativeResources("discovery.k8s.io", "v1", "endpointslices"),
	)},
	"service":    {Type: ResultString, Resources: nativeResources("apps", "v1", "statefulsets")},
	"selector":   {Type: ResultString, Resources: combineNativeResources(nativeApps, nativeControllers)},
	"containers": {Type: ResultString, Resources: nativeTemplates},
	"images":     {Type: ResultString, Resources: nativeTemplates},

	"completions":     {Type: ResultString, Resources: nativeResources("batch", "v1", "jobs")},
	"duration":        {Type: ResultDuration, Resources: nativeResources("batch", "v1", "jobs")},
	"active":          {Type: ResultInteger, Resources: nativeResources("batch", "v1", "jobs", "cronjobs")},
	"succeeded":       {Type: ResultInteger, Resources: nativeResources("batch", "v1", "jobs")},
	"failed":          {Type: ResultInteger, Resources: nativeResources("batch", "v1", "jobs")},
	"schedule":        {Type: ResultString, Resources: nativeResources("batch", "v1", "cronjobs")},
	"suspended":       {Type: ResultBoolean, Resources: nativeResources("batch", "v1", "cronjobs")},
	"last-schedule":   {Type: ResultTimestamp, Resources: nativeResources("batch", "v1", "cronjobs")},
	"time-zone":       {Type: ResultString, Resources: nativeResources("batch", "v1", "cronjobs")},
	"last-successful": {Type: ResultTimestamp, Resources: nativeResources("batch", "v1", "cronjobs")},

	"reference":        {Type: ResultString, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},
	"targets":          {Type: ResultString, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},
	"minimum":          {Type: ResultInteger, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},
	"maximum":          {Type: ResultInteger, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},
	"current-replicas": {Type: ResultInteger, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},
	"conditions":       {Type: ResultString, Resources: nativeResources("autoscaling", "*", "horizontalpodautoscalers")},

	"min-available":       {Type: ResultString, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},
	"max-unavailable":     {Type: ResultString, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},
	"disruptions-allowed": {Type: ResultInteger, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},
	"current-healthy":     {Type: ResultInteger, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},
	"desired-healthy":     {Type: ResultInteger, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},
	"expected-pods":       {Type: ResultInteger, Resources: nativeResources("policy", "v1", "poddisruptionbudgets")},

	"service-type":     {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"cluster-ip":       {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"external-address": {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"ports": {Type: ResultString, Resources: combineNativeResources(
		nativeResources("", "v1", "services", "endpoints"),
		nativeResources("discovery.k8s.io", "v1", "endpointslices"),
		nativeResources("networking.k8s.io", "v1", "ingresses"),
	)},
	"service-selector":        {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"ip-families":             {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"session-affinity":        {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"external-traffic-policy": {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"internal-traffic-policy": {Type: ResultString, Resources: nativeResources("", "v1", "services")},
	"endpoint-count": {Type: ResultInteger, Resources: combineNativeResources(
		nativeResources("", "v1", "endpoints"), nativeResources("discovery.k8s.io", "v1", "endpointslices"),
	)},
	"addresses": {Type: ResultString, Resources: combineNativeResources(
		nativeResources("", "v1", "endpoints"), nativeResources("discovery.k8s.io", "v1", "endpointslices"),
	)},
	"ingress-class": {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "ingresses")},
	"hosts":         {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "ingresses")},
	"address":       {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "ingresses")},
	"tls":           {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "ingresses")},
	"pod-selector":  {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "networkpolicies")},
	"policy-types":  {Type: ResultString, Resources: nativeResources("networking.k8s.io", "v1", "networkpolicies")},
	"ingress-rules": {Type: ResultInteger, Resources: nativeResources("networking.k8s.io", "v1", "networkpolicies")},
	"egress-rules":  {Type: ResultInteger, Resources: nativeResources("networking.k8s.io", "v1", "networkpolicies")},

	"capacity":     {Type: ResultQuantity, Resources: nativeResources("", "v1", "persistentvolumes", "persistentvolumeclaims")},
	"access-modes": {Type: ResultString, Resources: nativeResources("", "v1", "persistentvolumes", "persistentvolumeclaims")},
	"reclaim-policy": {Type: ResultString, Resources: combineNativeResources(
		nativeResources("", "v1", "persistentvolumes"), nativeResources("storage.k8s.io", "v1", "storageclasses"),
	)},
	"claim":         {Type: ResultString, Resources: nativeResources("", "v1", "persistentvolumes")},
	"storage-class": {Type: ResultString, Resources: nativeResources("", "v1", "persistentvolumes", "persistentvolumeclaims")},
	"volume":        {Type: ResultString, Resources: nativeResources("", "v1", "persistentvolumeclaims")},
	"reason": {Type: ResultString, Resources: combineNativeResources(
		nativeResources("", "v1", "persistentvolumes", "persistentvolumeclaims", "events"),
	)},
	"volume-mode":     {Type: ResultString, Resources: nativeResources("", "v1", "persistentvolumes", "persistentvolumeclaims")},
	"provisioner":     {Type: ResultString, Resources: nativeResources("storage.k8s.io", "v1", "storageclasses")},
	"binding-mode":    {Type: ResultString, Resources: nativeResources("storage.k8s.io", "v1", "storageclasses")},
	"allow-expansion": {Type: ResultBoolean, Resources: nativeResources("storage.k8s.io", "v1", "storageclasses")},
	"parameters":      {Type: ResultString, Resources: nativeResources("storage.k8s.io", "v1", "storageclasses")},

	"rule-count":    {Type: ResultInteger, Resources: nativeResources("rbac.authorization.k8s.io", "v1", "roles", "clusterroles")},
	"rules-summary": {Type: ResultString, Resources: nativeResources("rbac.authorization.k8s.io", "v1", "roles", "clusterroles")},
	"role-ref":      {Type: ResultString, Resources: nativeResources("rbac.authorization.k8s.io", "v1", "rolebindings", "clusterrolebindings")},
	"subject-kinds": {Type: ResultString, Resources: nativeResources("rbac.authorization.k8s.io", "v1", "rolebindings", "clusterrolebindings")},
	"subjects":      {Type: ResultString, Resources: nativeResources("rbac.authorization.k8s.io", "v1", "rolebindings", "clusterrolebindings")},

	"crd-group":       {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},
	"crd-kind":        {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},
	"served-versions": {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},
	"scope":           {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},
	"short-names":     {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},
	"categories":      {Type: ResultString, Resources: nativeResources("apiextensions.k8s.io", "v1", "customresourcedefinitions")},

	"last-seen":              {Type: ResultTimestamp, Resources: nativeResources("", "v1", "events")},
	"event-type":             {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"involved-object":        {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"message":                {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"event-source":           {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"subobject":              {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"first-seen":             {Type: ResultTimestamp, Resources: nativeResources("", "v1", "events")},
	"event-count":            {Type: ResultInteger, Resources: nativeResources("", "v1", "events")},
	"event-name":             {Type: ResultString, Resources: nativeResources("", "v1", "events")},
	"key-count":              {Type: ResultInteger, Resources: nativeResources("", "v1", "configmaps")},
	"secret-type":            {Type: ResultString, Resources: nativeResources("", "v1", "secrets")},
	"data-key-count":         {Type: ResultInteger, Resources: nativeResources("", "v1", "secrets")},
	"secret-refs":            {Type: ResultInteger, Resources: nativeResources("", "v1", "serviceaccounts")},
	"image-pull-secret-refs": {Type: ResultInteger, Resources: nativeResources("", "v1", "serviceaccounts")},
}

var nativeDefaultColumns = map[NativeResource][]string{
	{Group: "", Version: "v1", Resource: "pods"}: {
		"ready", "status", "restarts", "pod-ip", "node", "cpu", "memory", "age",
	},
	{Group: "", Version: "v1", Resource: "nodes"}: {
		"status", "roles", "taints", "internal-ip", "kubelet-version", "cpu", "memory", "age",
	},
	{Group: "apps", Version: "v1", Resource: "deployments"}: {
		"ready", "up-to-date", "available", "age",
	},
	{Group: "apps", Version: "v1", Resource: "statefulsets"}: {
		"ready", "service", "age",
	},
	{Group: "apps", Version: "v1", Resource: "daemonsets"}: {
		"desired", "current", "ready-count", "up-to-date", "available", "age",
	},
	{Group: "apps", Version: "v1", Resource: "replicasets"}: {
		"desired", "current", "ready-count", "age",
	},
	{Group: "", Version: "v1", Resource: "replicationcontrollers"}: {
		"desired", "current", "ready-count", "age",
	},
	{Group: "batch", Version: "v1", Resource: "jobs"}: {
		"status", "completions", "duration", "age",
	},
	{Group: "batch", Version: "v1", Resource: "cronjobs"}: {
		"schedule", "suspended", "active", "last-schedule", "age",
	},
	{Group: "autoscaling", Version: "*", Resource: "horizontalpodautoscalers"}: {
		"reference", "targets", "minimum", "maximum", "current-replicas", "age",
	},
	{Group: "policy", Version: "v1", Resource: "poddisruptionbudgets"}: {
		"min-available", "max-unavailable", "disruptions-allowed", "current-healthy", "desired-healthy", "age",
	},
	{Group: "", Version: "v1", Resource: "services"}: {
		"service-type", "cluster-ip", "external-address", "ports", "age",
	},
	{Group: "", Version: "v1", Resource: "endpoints"}: {
		"endpoint-count", "ports", "age",
	},
	{Group: "discovery.k8s.io", Version: "v1", Resource: "endpointslices"}: {
		"endpoint-count", "ready-count", "ports", "age",
	},
	{Group: "networking.k8s.io", Version: "v1", Resource: "ingresses"}: {
		"ingress-class", "hosts", "address", "ports", "age",
	},
	{Group: "networking.k8s.io", Version: "v1", Resource: "networkpolicies"}: {
		"pod-selector", "policy-types", "age",
	},
	{Group: "", Version: "v1", Resource: "persistentvolumes"}: {
		"capacity", "access-modes", "reclaim-policy", "status", "claim", "storage-class", "age",
	},
	{Group: "", Version: "v1", Resource: "persistentvolumeclaims"}: {
		"status", "volume", "capacity", "access-modes", "storage-class", "age",
	},
	{Group: "storage.k8s.io", Version: "v1", Resource: "storageclasses"}: {
		"provisioner", "reclaim-policy", "binding-mode", "allow-expansion", "age",
	},
	{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "roles"}: {
		"rule-count", "age",
	},
	{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterroles"}: {
		"rule-count", "age",
	},
	{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "rolebindings"}: {
		"role-ref", "subject-kinds", "subjects", "age",
	},
	{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterrolebindings"}: {
		"role-ref", "subject-kinds", "subjects", "age",
	},
	{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: {
		"crd-group", "crd-kind", "served-versions", "scope", "age",
	},
	{Group: "", Version: "v1", Resource: "events"}: {
		"last-seen", "event-type", "reason", "involved-object", "message",
	},
	{Group: "", Version: "v1", Resource: "configmaps"}: {
		"key-count", "age",
	},
	{Group: "", Version: "v1", Resource: "secrets"}: {
		"secret-type", "data-key-count", "age",
	},
	{Group: "", Version: "v1", Resource: "serviceaccounts"}: {"age"},
	{Group: "", Version: "v1", Resource: "namespaces"}:      {"status", "age"},
}

func NativeExtractor(value string) (NativeExtractorDefinition, bool) {
	definition, ok := NativeExtractorDefinitions[value]
	return definition, ok
}

func NativeExtractorSupports(value, group, version, resource string) bool {
	definition, ok := NativeExtractor(value)
	if !ok {
		return false
	}
	if definition.Resources == nil {
		return true
	}
	for _, candidate := range definition.Resources {
		if candidate.Group == group && candidate.Resource == resource &&
			(candidate.Version == "*" || candidate.Version == version) {
			return true
		}
	}
	return false
}

// HasCuratedNativeColumns decides whether a view uses local extraction or the
// apiserver's Table representation. Common metadata alone does not make an
// otherwise unknown resource curated.
func HasCuratedNativeColumns(group, version, resource string) bool {
	_, exact := nativeDefaultColumns[NativeResource{Group: group, Version: version, Resource: resource}]
	_, wildcard := nativeDefaultColumns[NativeResource{Group: group, Version: "*", Resource: resource}]
	return exact || wildcard
}

// DefaultNativeColumns returns the compact visible native layout for one
// curated resource. Callers prepend identity columns according to scope.
func DefaultNativeColumns(group, version, resource string) []string {
	columns := nativeDefaultColumns[NativeResource{Group: group, Version: version, Resource: resource}]
	if columns == nil {
		columns = nativeDefaultColumns[NativeResource{Group: group, Version: "*", Resource: resource}]
	}
	return append([]string(nil), columns...)
}
