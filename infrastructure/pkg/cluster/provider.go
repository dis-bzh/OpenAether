package cluster

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// ClusterProvider defines the contract for Cloud Providers (Docker, Scaleway, AWS, etc.)
// to provision infrastructure for a Talos cluster.
type ClusterProvider interface {
	// ProvisionNodes provisions the node infrastructure (VMs, Containers) and returns the IP of the first control plane node.
	// It is responsible for applying the initial Machine Configuration to the nodes.
	ProvisionNodes(ctx *pulumi.Context, name string, config *ClusterConfig, machineSecrets *machine.Secrets, cpConfig *machine.GetConfigurationResultOutput, workerConfig *machine.GetConfigurationResultOutput) (pulumi.StringOutput, error)

	// GetControlPlaneEndpoint returns the address to reach the Kubernetes API Server (VIP or Load Balancer).
	GetControlPlaneEndpoint(ctx *pulumi.Context) pulumi.StringOutput

	// GetConfigurationApplyNode returns the node IP to be used for config apply (e.g. 127.0.0.1 for local docker).
	// This might differ from the internal node IP.
	GetConfigurationApplyNode(ctx *pulumi.Context, internalNodeIp pulumi.StringOutput) pulumi.StringOutput
}
