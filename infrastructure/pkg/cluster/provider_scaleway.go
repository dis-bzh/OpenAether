package cluster

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-scaleway/sdk/go/scaleway"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

type ScalewayProvider struct{}

func NewScalewayProvider() *ScalewayProvider {
	return &ScalewayProvider{}
}

func (p *ScalewayProvider) GetControlPlaneEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	// For Scaleway, this would typically be a LoadBalancer IP
	// For this simulation, we probably don't have a static one yet unless passed via config.Endpoint
	return pulumi.String("").ToStringOutput()
}

func (p *ScalewayProvider) GetConfigurationApplyNode(ctx *pulumi.Context, internalNodeIp pulumi.StringOutput) pulumi.StringOutput {
	// Access via Public IP
	return internalNodeIp
}

func (p *ScalewayProvider) ProvisionNodes(ctx *pulumi.Context, name string, config *ClusterConfig, machineSecrets *machine.Secrets, cpConfig *machine.GetConfigurationResultOutput) (pulumi.StringOutput, error) {
	var firstNodeIp pulumi.StringOutput

	// Use values from the config
	instanceType := config.Scaleway.Type
	image := config.Scaleway.Image

	for i := 0; i < config.ControlPlaneNodes; i++ {
		nodeName := fmt.Sprintf("%s-cp-%d", name, i)
		server, err := scaleway.NewInstanceServer(ctx, nodeName, &scaleway.InstanceServerArgs{
			Type:  pulumi.String(instanceType),
			Image: pulumi.String(image),
			Tags:  pulumi.StringArray{pulumi.String("role=control-plane")},
		})
		if err != nil {
			return pulumi.StringOutput{}, err
		}
		if i == 0 {
			// We capture the Public IP of the first node for bootstrapping
			// Assuming DEV instances have public IPs attached or we might need to attach one.
			firstNodeIp = server.PublicIps.Index(pulumi.Int(0)).Address().Elem()
		}
	}

	return firstNodeIp, nil
}
