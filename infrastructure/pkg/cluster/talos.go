package cluster

import (
	"fmt"

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

	// 2. Generate Machine Configuration (Control Plane)
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

	// 3. Provision Infrastructure via Provider
	// The provider handles Node creation, Networking, and initial Config Apply if needed (or we can do it here if generic)
	// For Docker, we did Config Apply inside the provider because of the "localhost" port mapping nuance.
	// Let's assume the provider returns the Bootstrap Node IP.
	bootstrapNodeIp, err := provider.ProvisionNodes(ctx, name, config, secrets, &cpConfig)
	if err != nil {
		return nil, err
	}

	// 4. Wait for Talos to be ready (Generic Wait)
	// We use the node IP returned by the provider for checking readiness.
	// For Docker, this is 127.0.0.1. For others, it might be a public IP.

	// 5. Bootstrap Cluster
	// Only needed for the first node
	_, err = machine.NewBootstrap(ctx, name+"-bootstrap", &machine.BootstrapArgs{
		ClientConfiguration: secrets.ClientConfiguration,
		Node:                bootstrapNodeIp,
		Endpoint:            bootstrapNodeIp,
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	ctx.Export("clusterInfo", pulumi.Sprintf("Provisioning Cluster %s with %d CPs", name, config.ControlPlaneNodes))

	// 5. Retrieve Kubeconfig (using Talos Provider Resource)
	kubeconfigRes, err := taloscluster.NewKubeconfig(ctx, name+"-kubeconfig", &taloscluster.KubeconfigArgs{
		ClientConfiguration: taloscluster.KubeconfigClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		Node:     bootstrapNodeIp,
		Endpoint: pulumi.String(config.Endpoint),
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}
	cluster.Kubeconfig = kubeconfigRes.KubeconfigRaw

	// 6. Retrieve Talosconfig
	// Since client.NewConfiguration isn't readily available or matching, we'll construct it manually for now to unblock the build
	// consistent with how we did it before but using the outputs directly.
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
`, name, name, config.Endpoint, config.Endpoint, c.CaCertificate, c.ClientCertificate, c.ClientKey), nil
	}).(pulumi.StringOutput)

	return cluster, nil
}
