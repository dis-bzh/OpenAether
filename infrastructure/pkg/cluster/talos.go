package cluster

import (
	"fmt"
	"strings"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	taloscluster "github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

type TalosCluster struct {
	pulumi.ResourceState
	Kubeconfig  pulumi.StringOutput
	Talosconfig pulumi.StringOutput
}

// NewTalosCluster creates a new abstract Talos Cluster using a specific Cloud Provider.
func NewTalosCluster(ctx *pulumi.Context, name string, config *ClusterConfig, provider ClusterProvider, opts ...pulumi.ResourceOption) (*TalosCluster, error) {
	cluster := &TalosCluster{}
	err := ctx.RegisterComponentResource("openaether:cluster:TalosCluster", name, cluster, opts...)
	if err != nil {
		return nil, err
	}

	// 1. Generate Machine Secrets
	secrets, err := machine.NewSecrets(ctx, name+"-secrets", &machine.SecretsArgs{
		TalosVersion: pulumi.String(config.TalosVersion),
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	// 3. Generate Machine Configuration (Control Plane)
	// WE USE INTERNAL ENDPOINT (Docker DNS or Private IP) FOR NODE-TO-NODE COMM
	cpConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:       pulumi.String(config.ClusterName),
		MachineType:       pulumi.String("controlplane"),
		ClusterEndpoint:   pulumi.Sprintf("https://%s:6443", config.Endpoint),
		MachineSecrets:    secrets.MachineSecrets,
		TalosVersion:      pulumi.String(config.TalosVersion),
		KubernetesVersion: pulumi.String(config.KubernetesVersion),
		Docs:              pulumi.Bool(false),
		Examples:          pulumi.Bool(false),
	}, pulumi.Parent(cluster))

	if err != nil {
		return nil, err
	}

	// 3b. Generate Machine Configuration (Worker)
	workerConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:       pulumi.String(config.ClusterName),
		MachineType:       pulumi.String("worker"),
		ClusterEndpoint:   pulumi.Sprintf("https://%s:6443", config.Endpoint),
		MachineSecrets:    secrets.MachineSecrets,
		TalosVersion:      pulumi.String(config.TalosVersion),
		KubernetesVersion: pulumi.String(config.KubernetesVersion),
		Docs:              pulumi.Bool(false),
		Examples:          pulumi.Bool(false),
	}, pulumi.Parent(cluster))

	if err != nil {
		return nil, err
	}

	// 4. Provision Infrastructure via Provider
	// The provider handles Node creation, Networking, and initial Config Apply
	bootstrapNodeIp, err := provider.ProvisionNodes(ctx, name, config, secrets, &cpConfig, &workerConfig)
	if err != nil {
		return nil, err
	}

	// 5. Bootstrap Cluster
	// Only needed for the first node
	_, err = machine.NewBootstrap(ctx, name+"-bootstrap", &machine.BootstrapArgs{
		ClientConfiguration: secrets.ClientConfiguration,
		Node:                bootstrapNodeIp,
		Endpoint:            bootstrapNodeIp, // Bootstrap direct via IP
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	ctx.Export("clusterInfo", pulumi.Sprintf("Provisioning Cluster %s with %d CPs", name, config.ControlPlaneNodes))

	// 6. Retrieve Kubeconfig (using Talos Provider Resource)
	// WE USE PUBLIC ENDPOINT FOR USER ACCESS (e.g., 127.0.0.1)
	kubeconfigRes, err := taloscluster.NewKubeconfig(ctx, name+"-kubeconfig", &taloscluster.KubeconfigArgs{
		ClientConfiguration: taloscluster.KubeconfigClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		Node:     bootstrapNodeIp,
		Endpoint: pulumi.String(config.PublicEndpoint),
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	// Patch Kubeconfig to use Public Endpoint (127.0.0.1) instead of internal hostname
	cluster.Kubeconfig = kubeconfigRes.KubeconfigRaw.ApplyT(func(kc string) (string, error) {
		return strings.ReplaceAll(kc, config.Endpoint, config.PublicEndpoint), nil
	}).(pulumi.StringOutput)

	// 7. Retrieve Talosconfig
	cluster.Talosconfig = secrets.ClientConfiguration.ApplyT(func(c machine.ClientConfiguration) (string, error) {
		return fmt.Sprintf(`context: %s
contexts:
  %s:
    endpoints:
    - %s
    nodes:
    - %s
    ca: %s
    crt: %s
    key: %s
`, name, name, config.PublicEndpoint, config.PublicEndpoint, c.CaCertificate, c.ClientCertificate, c.ClientKey), nil
	}).(pulumi.StringOutput)

	return cluster, nil
}
