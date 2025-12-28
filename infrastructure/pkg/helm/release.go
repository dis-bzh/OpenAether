// Package helm provides utilities for deploying Helm charts via Pulumi.
package helm

import (
	"github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes"
	helmv3 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/helm/v3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// ReleaseConfig holds configuration for a Helm chart deployment.
type ReleaseConfig struct {
	// Name of the Helm release
	Name string
	// Namespace to deploy into
	Namespace string
	// Helm chart name
	Chart string
	// Chart version
	Version string
	// Helm repository URL
	Repository string
	// Values to pass to the chart
	Values map[string]interface{}
	// CreateNamespace if true, creates the namespace
	CreateNamespace bool
	// Wait for resources to be ready
	Wait bool
	// Timeout in seconds
	Timeout int
}

// NewRelease creates a new Helm release using the Kubernetes provider.
func NewRelease(
	ctx *pulumi.Context,
	name string,
	cfg ReleaseConfig,
	kubeProvider *kubernetes.Provider,
	opts ...pulumi.ResourceOption,
) (*helmv3.Release, error) {

	timeout := cfg.Timeout
	if timeout == 0 {
		timeout = 300 // Default 5 minutes
	}

	// Convert values to pulumi.Map
	values := pulumi.Map{}
	for k, v := range cfg.Values {
		values[k] = convertToPulumiValue(v)
	}

	releaseArgs := &helmv3.ReleaseArgs{
		Name:            pulumi.String(cfg.Name),
		Namespace:       pulumi.String(cfg.Namespace),
		Chart:           pulumi.String(cfg.Chart),
		Version:         pulumi.String(cfg.Version),
		RepositoryOpts:  helmv3.RepositoryOptsArgs{Repo: pulumi.String(cfg.Repository)},
		Values:          values,
		CreateNamespace: pulumi.Bool(cfg.CreateNamespace),
		Timeout:         pulumi.Int(timeout),
	}

	// Add the kubernetes provider to options
	allOpts := append(opts, pulumi.Provider(kubeProvider))

	return helmv3.NewRelease(ctx, name, releaseArgs, allOpts...)
}

// convertToPulumiValue converts Go values to Pulumi-compatible values.
func convertToPulumiValue(v interface{}) pulumi.Input {
	switch val := v.(type) {
	case pulumi.StringOutput:
		// Already a Pulumi output, return as-is
		return val
	case pulumi.Input:
		// Any Pulumi Input type, return as-is
		return val
	case string:
		return pulumi.String(val)
	case int:
		return pulumi.Int(val)
	case bool:
		return pulumi.Bool(val)
	case float64:
		return pulumi.Float64(val)
	case map[string]interface{}:
		m := pulumi.Map{}
		for k, v := range val {
			m[k] = convertToPulumiValue(v)
		}
		return m
	case []interface{}:
		arr := pulumi.Array{}
		for _, item := range val {
			arr = append(arr, convertToPulumiValue(item))
		}
		return arr
	default:
		return pulumi.Any(val)
	}
}

// NewKubernetesProvider creates a new Kubernetes provider from a kubeconfig.
func NewKubernetesProvider(
	ctx *pulumi.Context,
	name string,
	kubeconfig pulumi.StringOutput,
	opts ...pulumi.ResourceOption,
) (*kubernetes.Provider, error) {
	return kubernetes.NewProvider(ctx, name, &kubernetes.ProviderArgs{
		Kubeconfig: kubeconfig,
	}, opts...)
}
