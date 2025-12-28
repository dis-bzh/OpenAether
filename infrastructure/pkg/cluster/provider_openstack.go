package cluster

import (
	"fmt"

	"github.com/pulumi/pulumi-openstack/sdk/v5/go/openstack/compute"
	"github.com/pulumi/pulumi-openstack/sdk/v5/go/openstack/networking"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// OpenStackConfig holds OpenStack-specific configuration.
type OpenStackConfig struct {
	Region          string
	FlavorName      string
	ImageID         string
	ExternalNetwork string // External network for floating IPs (e.g., "Ext-Net")
}

// OpenStackProvider implements a generic OpenStack provider.
// This can be used directly or embedded by cloud-specific providers (OVH, etc.)
type OpenStackProvider struct {
	config        OpenStackConfig
	providerName  string
	network       *networking.Network
	subnet        *networking.Subnet
	router        *networking.Router
	securityGroup *networking.SecGroup
	floatingIps   []*networking.FloatingIp
	firstCPIP     pulumi.StringOutput
}

// NewOpenStackProvider creates a new generic OpenStack provider.
func NewOpenStackProvider(name string, config OpenStackConfig) *OpenStackProvider {
	return &OpenStackProvider{
		config:       config,
		providerName: name,
	}
}

// Name returns the provider identifier.
func (p *OpenStackProvider) Name() string {
	return p.providerName
}

// GetPublicEndpoint returns the public endpoint (floating IP).
func (p *OpenStackProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return p.firstCPIP
}

// ConfigureNetworking creates Network, Subnet, Router, and Security Groups.
func (p *OpenStackProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error {
	// Create Network
	network, err := networking.NewNetwork(ctx, name+"-network", &networking.NetworkArgs{
		Name:         pulumi.String(name + "-network"),
		AdminStateUp: pulumi.Bool(true),
	})
	if err != nil {
		return err
	}
	p.network = network

	// Create Subnet
	subnet, err := networking.NewSubnet(ctx, name+"-subnet", &networking.SubnetArgs{
		Name:      pulumi.String(name + "-subnet"),
		NetworkId: network.ID(),
		Cidr:      pulumi.String("10.0.0.0/24"),
		IpVersion: pulumi.Int(4),
		DnsNameservers: pulumi.StringArray{
			pulumi.String("8.8.8.8"),
			pulumi.String("8.8.4.4"),
		},
	})
	if err != nil {
		return err
	}
	p.subnet = subnet

	// Create Router
	router, err := networking.NewRouter(ctx, name+"-router", &networking.RouterArgs{
		Name:              pulumi.String(name + "-router"),
		AdminStateUp:      pulumi.Bool(true),
		ExternalNetworkId: pulumi.String(p.config.ExternalNetwork),
	})
	if err != nil {
		return err
	}
	p.router = router

	// Attach Router to Subnet
	_, err = networking.NewRouterInterface(ctx, name+"-router-interface", &networking.RouterInterfaceArgs{
		RouterId: router.ID(),
		SubnetId: subnet.ID(),
	})
	if err != nil {
		return err
	}

	// Create Security Group
	sg, err := networking.NewSecGroup(ctx, name+"-sg", &networking.SecGroupArgs{
		Name:        pulumi.String(name + "-sg"),
		Description: pulumi.String("OpenAether Talos cluster security group"),
	})
	if err != nil {
		return err
	}
	p.securityGroup = sg

	// Security Group Rules
	rules := []struct {
		name         string
		fromPort     int
		toPort       int
		protocol     string
		remotePrefix string
	}{
		{"ssh", 22, 22, "tcp", "0.0.0.0/0"},
		{"talos-api", 50000, 50001, "tcp", "0.0.0.0/0"},
		{"k8s-api", 6443, 6443, "tcp", "0.0.0.0/0"},
		{"etcd", 2379, 2380, "tcp", "10.0.0.0/8"},
		{"kubelet", 10250, 10250, "tcp", "10.0.0.0/8"},
		{"http", 80, 80, "tcp", "0.0.0.0/0"},
		{"https", 443, 443, "tcp", "0.0.0.0/0"},
		{"wireguard", 51871, 51871, "udp", "0.0.0.0/0"},
		{"vxlan", 8472, 8472, "udp", "0.0.0.0/0"},
	}

	for _, rule := range rules {
		_, err := networking.NewSecGroupRule(ctx, name+"-sg-"+rule.name, &networking.SecGroupRuleArgs{
			SecurityGroupId: sg.ID(),
			Direction:       pulumi.String("ingress"),
			Ethertype:       pulumi.String("IPv4"),
			Protocol:        pulumi.String(rule.protocol),
			PortRangeMin:    pulumi.Int(rule.fromPort),
			PortRangeMax:    pulumi.Int(rule.toPort),
			RemoteIpPrefix:  pulumi.String(rule.remotePrefix),
		})
		if err != nil {
			return err
		}
	}

	return nil
}

// ProvisionNodes provisions OpenStack Instances as Talos nodes.
func (p *OpenStackProvider) ProvisionNodes(
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

		// Create Floating IP
		fip, err := networking.NewFloatingIp(ctx, nodeName+"-fip", &networking.FloatingIpArgs{
			Pool: pulumi.String(p.config.ExternalNetwork),
		})
		if err != nil {
			return ProvisionedNode{}, err
		}
		p.floatingIps = append(p.floatingIps, fip)

		// Create Instance
		server, err := compute.NewInstance(ctx, nodeName, &compute.InstanceArgs{
			Name:           pulumi.String(nodeName),
			ImageId:        pulumi.String(p.config.ImageID),
			FlavorName:     pulumi.String(p.config.FlavorName),
			SecurityGroups: pulumi.StringArray{p.securityGroup.Name},
			Networks: compute.InstanceNetworkArray{
				&compute.InstanceNetworkArgs{
					Uuid: p.network.ID(),
				},
			},
			Metadata: pulumi.StringMap{
				"role":    pulumi.String(role),
				"cluster": pulumi.String(name),
			},
		})
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Associate Floating IP to instance's first network port
		// We need to get the port ID from the instance after it's created
		portId := server.Networks.Index(pulumi.Int(0)).Port().Elem()

		_, err = networking.NewFloatingIpAssociate(ctx, nodeName+"-fip-assoc", &networking.FloatingIpAssociateArgs{
			FloatingIp: fip.Address,
			PortId:     portId,
		}, pulumi.DependsOn([]pulumi.Resource{server}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Apply Talos configuration via floating IP
		_, err = machine.NewConfigurationApply(ctx, nodeName+"-apply", &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: (*configOutput).MachineConfiguration(),
			Node:                      fip.Address,
			Endpoint:                  fip.Address,
		}, pulumi.DependsOn([]pulumi.Resource{server}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		node := ProvisionedNode{
			Name:       nodeName,
			Role:       role,
			Provider:   p.providerName,
			InternalIP: server.AccessIpV4,
			PublicIP:   fip.Address,
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
