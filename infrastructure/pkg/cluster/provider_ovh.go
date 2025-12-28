package cluster

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// OvhProvider implements ClusterProvider for OVH Public Cloud (OpenStack based).
// It delegates most operations to the generic OpenStackProvider.
type OvhProvider struct {
	*OpenStackProvider
}

// NewOvhProvider creates a new OVH provider.
// OVH uses OpenStack under the hood, so we wrap the generic OpenStack provider.
func NewOvhProvider() *OvhProvider {
	return &OvhProvider{
		OpenStackProvider: nil, // Will be initialized in ConfigureNetworking
	}
}

// Name returns the provider identifier.
func (p *OvhProvider) Name() string {
	return "ovh"
}

// GetPublicEndpoint returns the public endpoint for OVH.
func (p *OvhProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	if p.OpenStackProvider != nil {
		return p.OpenStackProvider.GetPublicEndpoint(ctx)
	}
	return pulumi.String("").ToStringOutput()
}

// ConfigureNetworking initializes the underlying OpenStack provider and configures networking.
func (p *OvhProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error {
	// Initialize the OpenStack provider with OVH-specific config
	osConfig := OpenStackConfig{
		Region:          config.Ovh.Region,
		FlavorName:      config.Ovh.FlavorName,
		ImageID:         config.Ovh.ImageID,
		ExternalNetwork: "Ext-Net", // OVH's external network name
	}

	p.OpenStackProvider = NewOpenStackProvider("ovh", osConfig)

	// Delegate to OpenStack provider
	return p.OpenStackProvider.ConfigureNetworking(ctx, name, config)
}

// ProvisionNodes provisions OVH Instances as Talos nodes.
func (p *OvhProvider) ProvisionNodes(
	ctx *pulumi.Context,
	name string,
	config *ClusterConfig,
	distribution NodeDistribution,
	globalNodeIndex int,
	machineSecrets *machine.Secrets,
	cpConfig *machine.GetConfigurationResultOutput,
	workerConfig *machine.GetConfigurationResultOutput,
) ([]ProvisionedNode, pulumi.StringOutput, error) {

	// Ensure OpenStack provider is initialized
	if p.OpenStackProvider == nil {
		if err := p.ConfigureNetworking(ctx, name, config); err != nil {
			return nil, pulumi.StringOutput{}, err
		}
	}

	// Delegate to OpenStack provider
	return p.OpenStackProvider.ProvisionNodes(
		ctx, name, config, distribution, globalNodeIndex,
		machineSecrets, cpConfig, workerConfig,
	)
}
