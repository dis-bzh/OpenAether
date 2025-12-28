package cluster

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// ProvisionedNode contains information about a provisioned node.
type ProvisionedNode struct {
	Name       string
	Role       string // "controlplane" or "worker"
	Provider   string
	InternalIP pulumi.StringOutput
	PublicIP   pulumi.StringOutput
	Container  pulumi.Resource // For dependency tracking
}

// ClusterProvider defines the contract for Cloud Providers (Docker, Scaleway, OVH, Outscale, etc.)
// to provision infrastructure for a Talos cluster.
//
// In multi-provider mode, each provider is called with only its assigned nodes.
type ClusterProvider interface {
	// Name returns the provider identifier (e.g., "docker", "ovh", "outscale").
	Name() string

	// ProvisionNodes provisions the node infrastructure (VMs, Containers) and returns info about created nodes.
	// Parameters:
	//   - ctx: Pulumi context
	//   - name: Base name for resources
	//   - config: Full cluster configuration
	//   - distribution: This provider's node distribution (how many CP/workers to create)
	//   - globalNodeIndex: Starting index for node naming (for unique names across providers)
	//   - machineSecrets: Talos machine secrets
	//   - cpConfig: Control plane machine configuration
	//   - workerConfig: Worker machine configuration
	//
	// Returns:
	//   - List of provisioned nodes with their IPs
	//   - IP of the first control plane node (for bootstrap)
	//   - Error if provisioning fails
	ProvisionNodes(
		ctx *pulumi.Context,
		name string,
		config *ClusterConfig,
		distribution NodeDistribution,
		globalNodeIndex int,
		machineSecrets *machine.Secrets,
		cpConfig *machine.GetConfigurationResultOutput,
		workerConfig *machine.GetConfigurationResultOutput,
	) ([]ProvisionedNode, pulumi.StringOutput, error)

	// GetPublicEndpoint returns the public endpoint for this provider's nodes.
	// For Docker: 127.0.0.1
	// For cloud: Load Balancer IP or first node public IP
	GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput

	// ConfigureNetworking sets up provider-specific networking.
	// For cross-cloud, this may include VPN setup, security groups, etc.
	ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error
}

// ProviderRegistry holds all available providers.
type ProviderRegistry struct {
	providers map[string]ClusterProvider
}

// NewProviderRegistry creates a new provider registry with all available providers.
func NewProviderRegistry() *ProviderRegistry {
	return &ProviderRegistry{
		providers: map[string]ClusterProvider{
			"docker":   NewDockerProvider(),
			"outscale": NewOutscaleProvider(),
			"scaleway": NewScalewayProvider(),
			"ovh":      NewOvhProvider(),
		},
	}
}

// Get returns a provider by name.
func (r *ProviderRegistry) Get(name string) (ClusterProvider, bool) {
	p, ok := r.providers[name]
	return p, ok
}

// Register adds a new provider to the registry.
func (r *ProviderRegistry) Register(name string, provider ClusterProvider) {
	r.providers[name] = provider
}
