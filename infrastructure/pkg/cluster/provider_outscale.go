package cluster

import (
	"fmt"

	"github.com/pulumi/pulumi-terraform-provider/sdks/go/outscale/outscale"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// OutscaleProvider implements ClusterProvider for Outscale Cloud.
type OutscaleProvider struct {
	// Provider state
	net             *outscale.Net
	subnet          *outscale.Subnet
	securityGroup   *outscale.SecurityGroup
	publicIps       []*outscale.PublicIp
	firstCPPublicIp *outscale.PublicIp // Pre-allocated IP for first CP
}

// NewOutscaleProvider creates a new Outscale provider.
func NewOutscaleProvider() *OutscaleProvider {
	return &OutscaleProvider{}
}

// Name returns the provider identifier.
func (p *OutscaleProvider) Name() string {
	return "outscale"
}

// GetPublicEndpoint returns the public endpoint for Outscale.
func (p *OutscaleProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	if p.firstCPPublicIp != nil {
		return p.firstCPPublicIp.PublicIp
	}
	if len(p.publicIps) > 0 {
		return p.publicIps[0].PublicIp
	}
	return pulumi.String("").ToStringOutput()
}

// ConfigureNetworking creates the VPC, Subnet, and Security Groups for Outscale.
func (p *OutscaleProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error {
	// Create VPC (Net)
	net, err := outscale.NewNet(ctx, name+"-net", &outscale.NetArgs{
		IpRange: pulumi.String("10.0.0.0/16"),
		Tags: outscale.NetTagArray{
			&outscale.NetTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-net"),
			},
			&outscale.NetTagArgs{
				Key:   pulumi.String("osc.fcu.eip.auto-attach"),
				Value: pulumi.String("true"),
			},
		},
	})
	if err != nil {
		return err
	}
	p.net = net

	// Create Subnet
	subnet, err := outscale.NewSubnet(ctx, name+"-subnet", &outscale.SubnetArgs{
		NetId:         net.NetId,
		IpRange:       pulumi.String("10.0.1.0/24"),
		SubregionName: pulumi.String(config.Outscale.Region + "a"),
		Tags: outscale.SubnetTagArray{
			&outscale.SubnetTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-subnet"),
			},
		},
	})
	if err != nil {
		return err
	}
	p.subnet = subnet

	// Create Internet Gateway
	igw, err := outscale.NewInternetService(ctx, name+"-igw", &outscale.InternetServiceArgs{
		Tags: outscale.InternetServiceTagArray{
			&outscale.InternetServiceTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-igw"),
			},
		},
	})
	if err != nil {
		return err
	}

	// Link Internet Gateway to Net
	_, err = outscale.NewInternetServiceLink(ctx, name+"-igw-link", &outscale.InternetServiceLinkArgs{
		NetId:             net.NetId,
		InternetServiceId: igw.InternetServiceId,
	})
	if err != nil {
		return err
	}

	// Create Route Table with default route to IGW
	rt, err := outscale.NewRouteTable(ctx, name+"-rt", &outscale.RouteTableArgs{
		NetId: net.NetId,
		Tags: outscale.RouteTableTagArray{
			&outscale.RouteTableTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-rt"),
			},
		},
	})
	if err != nil {
		return err
	}

	// Add default route
	_, err = outscale.NewRoute(ctx, name+"-route-default", &outscale.RouteArgs{
		RouteTableId:       rt.RouteTableId,
		DestinationIpRange: pulumi.String("0.0.0.0/0"),
		GatewayId:          igw.InternetServiceId,
	})
	if err != nil {
		return err
	}

	// Link Route Table to Subnet
	_, err = outscale.NewRouteTableLink(ctx, name+"-rt-link", &outscale.RouteTableLinkArgs{
		RouteTableId: rt.RouteTableId,
		SubnetId:     subnet.SubnetId,
	})
	if err != nil {
		return err
	}

	// Create Security Group
	sg, err := outscale.NewSecurityGroup(ctx, name+"-sg", &outscale.SecurityGroupArgs{
		NetId:             net.NetId,
		SecurityGroupName: pulumi.String(name + "-sg"),
		Description:       pulumi.String("OpenAether Talos cluster security group"),
		Tags: outscale.SecurityGroupTagArray{
			&outscale.SecurityGroupTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-sg"),
			},
		},
	})
	if err != nil {
		return err
	}
	p.securityGroup = sg

	// Security Group Rules
	rules := []struct {
		name     string
		fromPort int
		toPort   int
		protocol string
	}{
		{"ssh", 22, 22, "tcp"},
		{"talos-api", 50000, 50001, "tcp"},
		{"k8s-api", 6443, 6443, "tcp"},
		{"etcd", 2379, 2380, "tcp"},
		{"kubelet", 10250, 10250, "tcp"},
		{"http", 80, 80, "tcp"},
		{"https", 443, 443, "tcp"},
		{"wireguard", 51871, 51871, "udp"},
		{"vxlan", 8472, 8472, "udp"},
	}

	for _, rule := range rules {
		_, err := outscale.NewSecurityGroupRule(ctx, name+"-sg-"+rule.name, &outscale.SecurityGroupRuleArgs{
			SecurityGroupId: sg.SecurityGroupId,
			Flow:            pulumi.String("Inbound"),
			FromPortRange:   pulumi.Float64(rule.fromPort),
			ToPortRange:     pulumi.Float64(rule.toPort),
			IpProtocol:      pulumi.String(rule.protocol),
			IpRange:         pulumi.String("0.0.0.0/0"),
		})
		if err != nil {
			return err
		}
	}

	// Pre-allocate Public IP for the first control plane node
	// This is needed so GetPublicEndpoint can return the IP before ProvisionNodes is called
	firstCPIp, err := outscale.NewPublicIp(ctx, name+"-cp-0-ip-prealloc", &outscale.PublicIpArgs{
		Tags: outscale.PublicIpTagArray{
			&outscale.PublicIpTagArgs{
				Key:   pulumi.String("Name"),
				Value: pulumi.String(name + "-cp-0"),
			},
		},
	})
	if err != nil {
		return err
	}
	p.firstCPPublicIp = firstCPIp
	p.publicIps = append(p.publicIps, firstCPIp)

	return nil
}

// ProvisionNodes provisions Outscale VMs as Talos nodes.
func (p *OutscaleProvider) ProvisionNodes(
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

	// Helper to create a VM
	createVM := func(role string, localIndex int, configOutput *machine.GetConfigurationResultOutput) (ProvisionedNode, error) {
		nodeName := fmt.Sprintf("%s-%s-%d", name, role, nodeIndex)

		var publicIp *outscale.PublicIp
		var err error

		// Reuse pre-allocated IP for first control plane
		if role == "cp" && localIndex == 0 && p.firstCPPublicIp != nil {
			publicIp = p.firstCPPublicIp
		} else {
			// Create new Public IP
			publicIp, err = outscale.NewPublicIp(ctx, nodeName+"-ip", &outscale.PublicIpArgs{
				Tags: outscale.PublicIpTagArray{
					&outscale.PublicIpTagArgs{
						Key:   pulumi.String("Name"),
						Value: pulumi.String(nodeName),
					},
				},
			})
			if err != nil {
				return ProvisionedNode{}, err
			}
			p.publicIps = append(p.publicIps, publicIp)
		}

		// Create VM
		vm, err := outscale.NewVm(ctx, nodeName, &outscale.VmArgs{
			ImageId:  pulumi.String(config.Outscale.ImageID),
			VmType:   pulumi.String(config.Outscale.InstanceType),
			SubnetId: p.subnet.SubnetId,
			SecurityGroupIds: pulumi.StringArray{
				p.securityGroup.SecurityGroupId,
			},
			Tags: outscale.VmTagArray{
				&outscale.VmTagArgs{
					Key:   pulumi.String("Name"),
					Value: pulumi.String(nodeName),
				},
				&outscale.VmTagArgs{
					Key:   pulumi.String("Role"),
					Value: pulumi.String(role),
				},
			},
		})
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Link Public IP to VM
		_, err = outscale.NewPublicIpLink(ctx, nodeName+"-ip-link", &outscale.PublicIpLinkArgs{
			PublicIp: publicIp.PublicIp,
			VmId:     vm.VmId,
		}, pulumi.DependsOn([]pulumi.Resource{vm}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Apply Talos configuration via public IP
		_, err = machine.NewConfigurationApply(ctx, nodeName+"-apply", &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: (*configOutput).MachineConfiguration(),
			Node:                      publicIp.PublicIp,
			Endpoint:                  publicIp.PublicIp,
		}, pulumi.DependsOn([]pulumi.Resource{vm}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		node := ProvisionedNode{
			Name:       nodeName,
			Role:       role,
			Provider:   "outscale",
			InternalIP: vm.PrivateIp,
			PublicIP:   publicIp.PublicIp,
			Container:  vm,
		}

		nodeIndex++
		return node, nil
	}

	// Provision Control Plane Nodes
	for i := 0; i < distribution.ControlPlanes; i++ {
		node, err := createVM("cp", i, cpConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)

		if i == 0 {
			firstCPIP = node.PublicIP
		}
	}

	// Provision Worker Nodes
	for i := 0; i < distribution.Workers; i++ {
		node, err := createVM("worker", i, workerConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)
	}

	return nodes, firstCPIP, nil
}
