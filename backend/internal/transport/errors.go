package transport

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/credentialexec"
	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

func kubeconfigError(err error, operation string) *kmgrv1.StructuredError {
	structured := &kmgrv1.StructuredError{
		Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION,
		Reason:    "KubeconfigInvalid",
		Message:   "Kubernetes configuration could not be loaded.",
		Operation: operation,
	}
	var notFound *cluster.ContextNotFoundError
	var unsupported *cluster.UnsupportedAuthenticationError
	var pluginNotFound *credentialexec.ExecutableNotFoundError
	var interactivePlugin *credentialexec.InteractiveModeUnsupportedError
	switch {
	case errors.As(err, &notFound):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		structured.Reason = "ContextNotFound"
		structured.Message = "The selected kubeconfig context no longer exists. Reload contexts and try again."
	case errors.As(err, &unsupported):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED
		structured.Reason = "UnsupportedAuthentication"
		structured.Message = unsupported.Error()
		structured.ContextName = unsupported.ContextName
	case errors.As(err, &pluginNotFound):
		structured.Reason = "CredentialPluginNotFound"
		structured.Message = "The kubeconfig credential plugin could not be found."
		structured.SafeDetails = map[string]string{"command": pluginNotFound.Command}
	case errors.As(err, &interactivePlugin):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED
		structured.Reason = "InteractiveCredentialPluginUnsupported"
		structured.Message = "This credential plugin requires terminal input, which kmgr does not provide."
	case isLocalTLSConfigurationError(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TLS
		structured.Reason = "TLSConfigurationInvalid"
		structured.Message = "TLS credentials or certificate-authority configuration could not be loaded."
	}
	return structured
}

func addedKubeconfigSourceError(err error) *kmgrv1.StructuredError {
	structured := kubeconfigError(err, "read added kubeconfig")
	switch {
	case errors.Is(err, cluster.ErrKubeconfigSourceAutomatic):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		structured.Reason = "KubeconfigAlreadyDiscovered"
		structured.Message = "This file is already read through $KUBECONFIG or ~/.kube."
	case errors.Is(err, cluster.ErrKubeconfigSourceDuplicate):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		structured.Reason = "KubeconfigAlreadyAdded"
		structured.Message = "This kubeconfig file is already in the added file list."
	case errors.Is(err, fs.ErrNotExist):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		structured.Reason = "KubeconfigFileMissing"
		structured.Message = "The kubeconfig file could not be found."
		structured.Retryable = true
	case errors.Is(err, fs.ErrPermission):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		structured.Reason = "KubeconfigFileUnreadable"
		structured.Message = "The kubeconfig file could not be read with the current permissions."
	case errors.Is(err, cluster.ErrKubeconfigSourceNotRegular):
		structured.Reason = "KubeconfigNotRegularFile"
		structured.Message = "The selected path is not a regular file."
	case errors.Is(err, cluster.ErrKubeconfigSourceNoContexts):
		structured.Reason = "KubeconfigHasNoContexts"
		structured.Message = "The kubeconfig file does not contain any contexts."
	}
	return structured
}

func isLocalTLSConfigurationError(err error) bool {
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "certificate-authority") ||
		strings.Contains(message, "client certificate") ||
		strings.Contains(message, "client key") ||
		strings.Contains(message, "private key") ||
		strings.Contains(message, "failed to find any pem data")
}

func connectionError(err error, contextName, serverHostname string) *kmgrv1.StructuredError {
	structured := &kmgrv1.StructuredError{
		Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
		Reason:      "ClusterUnreachable",
		Message:     "The Kubernetes API server could not be reached.",
		Retryable:   true,
		ContextName: contextName,
		Operation:   "open-session",
	}
	if serverHostname != "" {
		structured.SafeDetails = map[string]string{"server_hostname": serverHostname}
	}

	var apiStatus apierrors.APIStatus
	kubeerrors.Enrich(structured, err)
	switch {
	case credentialProxyExited(err, credentialexec.ProxyExitTimedOut):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		structured.Reason = "CredentialPluginTimedOut"
		structured.Message = "The kubeconfig credential plugin timed out."
	case credentialProxyExited(err, credentialexec.ProxyExitPluginNotFound):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		structured.Reason = "CredentialPluginNotFound"
		structured.Message = "The kubeconfig credential plugin disappeared before it could run."
		structured.Retryable = false
	case isCredentialPluginError(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		structured.Reason = "CredentialPluginFailed"
		structured.Message = "The kubeconfig credential plugin failed."
	case errors.Is(err, context.DeadlineExceeded):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		structured.Reason = "ConnectionTimedOut"
		structured.Message = "Connecting to the Kubernetes API server timed out."
	case errors.Is(err, context.Canceled):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		structured.Reason = "ConnectionCancelled"
		structured.Message = "Connecting to the Kubernetes API server was cancelled."
		structured.Retryable = false
	case apierrors.IsUnauthorized(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		structured.Reason = "AuthenticationRejected"
		structured.Message = "The Kubernetes API server rejected the configured credentials."
		structured.Retryable = false
	case apierrors.IsForbidden(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		structured.Reason = "ConnectionProbeForbidden"
		structured.Message = "The configured identity is not allowed to query the Kubernetes API server version."
		structured.Retryable = false
	case isTLSError(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TLS
		structured.Reason = "TLSVerificationFailed"
		structured.Message = "TLS verification of the Kubernetes API server failed."
		structured.Retryable = false
	case apierrors.IsTimeout(err) || apierrors.IsServerTimeout(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		structured.Reason = "ServerTimeout"
		structured.Message = "The Kubernetes API server timed out while accepting the connection probe."
	case errors.As(err, &apiStatus):
		status := apiStatus.Status()
		if status.Reason != "" {
			structured.Reason = string(status.Reason)
		}
	case isNetworkTimeout(err):
		structured.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		structured.Reason = "NetworkTimeout"
		structured.Message = "The network timed out while connecting to the Kubernetes API server."
	}
	return structured
}

func credentialProxyExited(err error, code int) bool {
	return isCredentialPluginError(err) &&
		strings.Contains(err.Error(), "exec: executable ") &&
		strings.Contains(err.Error(), fmt.Sprintf("failed with exit code %d", code))
}

func isCredentialPluginError(err error) bool {
	if err == nil {
		return false
	}
	var apiStatus apierrors.APIStatus
	return !errors.As(err, &apiStatus) && strings.Contains(err.Error(), "getting credentials:")
}

func unsupportedAuthenticationError(info cluster.ContextInfo) *kmgrv1.StructuredError {
	mechanisms := make([]string, len(info.UnsupportedAuthentications))
	for index, mechanism := range info.UnsupportedAuthentications {
		mechanisms[index] = string(mechanism)
	}
	return &kmgrv1.StructuredError{
		Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED,
		Reason:      "UnsupportedAuthentication",
		Message:     "This context uses unsupported kubeconfig authentication: " + strings.Join(mechanisms, " and ") + ".",
		ContextName: info.Name,
		Operation:   "list-contexts",
		SafeDetails: map[string]string{"mechanisms": strings.Join(mechanisms, ",")},
	}
}

func isTLSError(err error) bool {
	var unknownAuthority x509.UnknownAuthorityError
	var invalidCertificate x509.CertificateInvalidError
	var hostname x509.HostnameError
	var systemRoots x509.SystemRootsError
	var verification *tls.CertificateVerificationError
	var recordHeader tls.RecordHeaderError
	if errors.As(err, &unknownAuthority) ||
		errors.As(err, &invalidCertificate) ||
		errors.As(err, &hostname) ||
		errors.As(err, &systemRoots) ||
		errors.As(err, &verification) ||
		errors.As(err, &recordHeader) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "x509:") ||
		strings.Contains(message, "tls:") ||
		strings.Contains(message, "certificate authority") ||
		strings.Contains(message, "client certificate")
}

func isNetworkTimeout(err error) bool {
	var networkError net.Error
	return errors.As(err, &networkError) && networkError.Timeout()
}
