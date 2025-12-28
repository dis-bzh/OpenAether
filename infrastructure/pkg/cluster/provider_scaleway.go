package cluster

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-scaleway/sdk/go/scaleway"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// ScalewayProvider implements ClusterProvider for Scaleway Cloud.
type ScalewayProvider struct {
	vpc           *scaleway.Vpc
	privateNet    *scaleway.VpcPrivateNetwork
	securityGroup *scaleway.InstanceSecurityGroup
	publicIps     []*scaleway.InstanceIp
	firstCPIP     pulumi.StringOutput
}

// NewScalewayProvider creates a new Scaleway provider.
func NewScalewayProvider() *ScalewayProvider {
	return &ScalewayProvider{}
}

// Name returns the provider identifier.
func (p *ScalewayProvider) Name() string {
	return "scaleway"
}

// GetPublicEndpoint returns the public endpoint for Scaleway.
func (p *ScalewayProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return p.firstCPIP
}

// ConfigureNetworking creates the VPC, Private Network, and Security Groups for Scaleway.
func (p *ScalewayProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error {
	// Create VPC
	vpc, err := scaleway.NewVpc(ctx, name+"-vpc", &scaleway.VpcArgs{
		Name:   pulumi.String(name + "-vpc"),
		Region: pulumi.String(config.Scaleway.Region),
		Tags: pulumi.StringArray{
			pulumi.String("openaether"),
			pulumi.String(name),
		},
	})
	if err != nil {
		return err
	}
	p.vpc = vpc

	// Create Private Network
	privateNet, err := scaleway.NewVpcPrivateNetwork(ctx, name+"-pn", &scaleway.VpcPrivateNetworkArgs{
		Name:   pulumi.String(name + "-pn"),
		VpcId:  vpc.ID(),
		Region: pulumi.String(config.Scaleway.Region),
		Tags: pulumi.StringArray{
			pulumi.String("openaether"),
		},
	})
	if err != nil {
		return err
	}
	p.privateNet = privateNet

	// Create Security Group for Talos
	sg, err := scaleway.NewInstanceSecurityGroup(ctx, name+"-sg", &scaleway.InstanceSecurityGroupArgs{
		Name:                  pulumi.String(name + "-sg"),
		Zone:                  pulumi.String(config.Scaleway.Zone),
		InboundDefaultPolicy:  pulumi.String("drop"),
		OutboundDefaultPolicy: pulumi.String("accept"),
		// SSH
		InboundRules: scaleway.InstanceSecurityGroupInboundRuleArray{
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(22),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			// Talos API
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(50000),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(50001),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			// Kubernetes API
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(6443),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			// etcd
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:    pulumi.String("accept"),
				PortRange: pulumi.String("2379-2380"),
				Protocol:  pulumi.String("TCP"),
				IpRange:   pulumi.String("10.0.0.0/8"),
			},
			// Kubelet
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(10250),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("10.0.0.0/8"),
			},
			// WireGuard (Cilium encryption)
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(51871),
				Protocol: pulumi.String("UDP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			// VXLAN (Cilium)
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(8472),
				Protocol: pulumi.String("UDP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			// HTTP/HTTPS
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(80),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
			&scaleway.InstanceSecurityGroupInboundRuleArgs{
				Action:   pulumi.String("accept"),
				Port:     pulumi.Int(443),
				Protocol: pulumi.String("TCP"),
				IpRange:  pulumi.String("0.0.0.0/0"),
			},
		},
	})
	if err != nil {
		return err
	}
	p.securityGroup = sg

	return nil
}

// ProvisionNodes provisions Scaleway Instances as Talos nodes.
func (p *ScalewayProvider) ProvisionNodes(
	ctx *pulumi.Context,
	name string,
	config *ClusterConfig,
	distribution NodeDistribution,
	globalNodeIndex int,
	machineSecrets *machine.Secrets,
	cpConfig *machine.GetConfigurationResultOutput,
	workerConfig *machine.GetConfigurationResultOutput,
) ([]ProvisionedNode, pulumi.StringOutput, error) {

	var nodes []ProvisionedNode
	var firstCPIP pulumi.StringOutput
	nodeIndex := globalNodeIndex

	// Helper to create an Instance
	createInstance := func(role string, localIndex int, configOutput *machine.GetConfigurationResultOutput) (ProvisionedNode, error) {
		nodeName := fmt.Sprintf("%s-%s-%d", name, role, nodeIndex)

		// Create Public IP
		publicIp, err := scaleway.NewInstanceIp(ctx, nodeName+"-ip", &scaleway.InstanceIpArgs{
			Zone: pulumi.String(config.Scaleway.Zone),
		})
		if err != nil {
			return ProvisionedNode{}, err
		}
		p.publicIps = append(p.publicIps, publicIp)

		// Create extra volume for EPHEMERAL partition
		// Scaleway Talos requires separate disk for EPHEMERAL
		ephemeralVolume, err := scaleway.NewInstanceVolume(ctx, nodeName+"-ephemeral", &scaleway.InstanceVolumeArgs{
			Name:     pulumi.String(nodeName + "-ephemeral"),
			Zone:     pulumi.String(config.Scaleway.Zone),
			Type:     pulumi.String("l_ssd"), // Local SSD for performance
			SizeInGb: pulumi.Int(25),         // 25GB for EPHEMERAL
		})
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Create Instance Server
		server, err := scaleway.NewInstanceServer(ctx, nodeName, &scaleway.InstanceServerArgs{
			Name:            pulumi.String(nodeName),
			Zone:            pulumi.String(config.Scaleway.Zone),
			Type:            pulumi.String(config.Scaleway.InstanceType),
			Image:           pulumi.String(config.Scaleway.SnapshotID), // Talos snapshot
			IpId:            publicIp.ID(),
			SecurityGroupId: p.securityGroup.ID(),
			Tags: pulumi.StringArray{
				pulumi.String("openaether"),
				pulumi.String(role),
			},
			AdditionalVolumeIds: pulumi.StringArray{
				ephemeralVolume.ID(),
			},
		})
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Apply Talos configuration via public IP
		_, err = machine.NewConfigurationApply(ctx, nodeName+"-apply", &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: (*configOutput).MachineConfiguration(),
			Node:                      publicIp.Address,
			Endpoint:                  publicIp.Address,
		}, pulumi.DependsOn([]pulumi.Resource{server}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		node := ProvisionedNode{
			Name:       nodeName,
			Role:       role,
			Provider:   "scaleway",
			InternalIP: publicIp.Address, // Scaleway Talos uses public IP
			PublicIP:   publicIp.Address,
			Container:  server,
		}

		nodeIndex++
		return node, nil
	}

	// Provision Control Plane Nodes
	for i := 0; i < distribution.ControlPlanes; i++ {
		node, err := createInstance("cp", i, cpConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)

		if i == 0 {
			firstCPIP = node.PublicIP
			p.firstCPIP = firstCPIP
		}
	}

	// Provision Worker Nodes
	for i := 0; i < distribution.Workers; i++ {
		node, err := createInstance("worker", i, workerConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)
	}

	return nodes, firstCPIP, nil
}
