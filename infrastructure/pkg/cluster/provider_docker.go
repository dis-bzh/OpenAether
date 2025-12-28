package cluster

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/pulumi/pulumi-docker/sdk/v4/go/docker"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
	"gopkg.in/yaml.v3"
)

type DockerProvider struct {
	// Provider-specific state
	lbContainer *docker.Container
}

func NewDockerProvider() *DockerProvider {
	return &DockerProvider{}
}

// Name returns the provider identifier.
func (p *DockerProvider) Name() string {
	return "docker"
}

// GetPublicEndpoint returns the public endpoint for Docker (localhost).
func (p *DockerProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return pulumi.String("127.0.0.1").ToStringOutput()
}

// ConfigureNetworking creates Docker networks for multi-cloud simulation.
func (p *DockerProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *ClusterConfig) error {
	internetNetworkName := config.Docker.NetworkName + "-internet"

	// Create the "Internet" Network (Shared between all clouds)
	_, err := docker.NewNetwork(ctx, internetNetworkName, &docker.NetworkArgs{
		Name:           pulumi.String(internetNetworkName),
		Driver:         pulumi.String("bridge"),
		CheckDuplicate: pulumi.Bool(true),
	})
	if err != nil {
		return err
	}

	// Create "Cloud" Networks (Private VPCs) for multi-cloud simulation
	for _, cloudName := range config.Docker.Clouds {
		netName := config.Docker.NetworkName + "-" + cloudName
		_, err := docker.NewNetwork(ctx, netName, &docker.NetworkArgs{
			Name:           pulumi.String(netName),
			Driver:         pulumi.String("bridge"),
			CheckDuplicate: pulumi.Bool(true),
			Internal:       pulumi.Bool(false), // Bridge for testing
		})
		if err != nil {
			return err
		}
	}

	return nil
}

// ProvisionNodes provisions Docker containers as Talos nodes.
func (p *DockerProvider) ProvisionNodes(
	ctx *pulumi.Context,
	name string,
	config *ClusterConfig,
	distribution NodeDistribution,
	globalNodeIndex int,
	machineSecrets *machine.Secrets,
	cpConfig *machine.GetConfigurationResultOutput,
	workerConfig *machine.GetConfigurationResultOutput,
) ([]ProvisionedNode, pulumi.StringOutput, error) {

	internetNetworkName := config.Docker.NetworkName + "-internet"
	var nodes []ProvisionedNode
	var firstCPIP pulumi.StringOutput

	nodeIndex := globalNodeIndex

	// Helper to create a node
	createNode := func(role string, localIndex int, configOutput *machine.GetConfigurationResultOutput) (ProvisionedNode, error) {
		nodeName := fmt.Sprintf("%s-%s-%d", name, role, nodeIndex)

		// Distribute nodes across simulated clouds
		cloudIndex := localIndex % len(config.Docker.Clouds)
		cloudName := config.Docker.Clouds[cloudIndex]
		cloudNetworkName := config.Docker.NetworkName + "-" + cloudName

		networks := []string{internetNetworkName, cloudNetworkName}

		container, err := p.createContainer(ctx, nodeName, config.TalosVersion, networks)
		if err != nil {
			return ProvisionedNode{}, err
		}

		// Retrieve IP address from the Internet Network
		containerInternalIP := container.NetworkDatas.ApplyT(func(datas []docker.ContainerNetworkData) (string, error) {
			for _, data := range datas {
				if data.NetworkName != nil && *data.NetworkName == internetNetworkName && data.IpAddress != nil && *data.IpAddress != "" {
					return *data.IpAddress, nil
				}
			}
			// Fallback: Use first IP found
			if len(datas) > 0 && datas[0].IpAddress != nil && *datas[0].IpAddress != "" {
				return *datas[0].IpAddress, nil
			}
			return "", fmt.Errorf("could not find IP address for node %s", nodeName)
		}).(pulumi.StringOutput)

		// Transform config for Docker
		containerConfig := p.transformConfig(configOutput.MachineConfiguration())

		// Apply Configuration
		_, err = machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-apply", nodeName), &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: containerConfig,
			Node:                      containerInternalIP,
			Endpoint:                  containerInternalIP,
		}, pulumi.Parent(container), pulumi.DependsOn([]pulumi.Resource{container}))
		if err != nil {
			return ProvisionedNode{}, err
		}

		node := ProvisionedNode{
			Name:       nodeName,
			Role:       role,
			Provider:   "docker",
			InternalIP: containerInternalIP,
			PublicIP:   pulumi.String("127.0.0.1").ToStringOutput(), // Docker uses localhost
			Container:  container,
		}

		nodeIndex++
		return node, nil
	}

	// Provision Control Plane Nodes
	for i := 0; i < distribution.ControlPlanes; i++ {
		node, err := createNode("cp", i, cpConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)

		if i == 0 {
			firstCPIP = node.InternalIP
		}
	}

	// Provision Worker Nodes
	for i := 0; i < distribution.Workers; i++ {
		node, err := createNode("worker", i, workerConfig)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}
		nodes = append(nodes, node)
	}

	return nodes, firstCPIP, nil
}

// CreateLoadBalancer creates an HAProxy container for the cluster.
func (p *DockerProvider) CreateLoadBalancer(ctx *pulumi.Context, name string, config *ClusterConfig, nodes []ProvisionedNode) (*docker.Container, error) {
	lbName := "openaether-local-lb"
	networkName := config.Docker.NetworkName + "-internet"

	// Collect node names by role
	var cpNodes, workerNodes []string
	for _, n := range nodes {
		if n.Role == "controlplane" || n.Role == "cp" {
			cpNodes = append(cpNodes, n.Name)
		} else {
			workerNodes = append(workerNodes, n.Name)
		}
	}

	// Generate HAProxy config
	var sb strings.Builder
	sb.WriteString(`
defaults
    mode tcp
    timeout connect 5s
    timeout client 1m
    timeout server 1m

frontend k8s_api
    bind *:6443
    default_backend k8s_api_backend

backend k8s_api_backend
`)
	for i, nodeName := range cpNodes {
		sb.WriteString(fmt.Sprintf("    server cp-%d %s:6443 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend talos_api
    bind *:50000
    default_backend talos_api_backend

backend talos_api_backend
`)
	for i, nodeName := range cpNodes {
		sb.WriteString(fmt.Sprintf("    server cp-%d %s:50000 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend ingress_http
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
`)
	for i, nodeName := range workerNodes {
		sb.WriteString(fmt.Sprintf("    server worker-%d %s:80 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend ingress_https
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
`)
	for i, nodeName := range workerNodes {
		sb.WriteString(fmt.Sprintf("    server worker-%d %s:443 check\n", i, nodeName))
	}

	// Write config to host
	wd, _ := os.Getwd()
	configDir := filepath.Join(wd, "haproxy")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return nil, err
	}
	configFile := filepath.Join(configDir, "haproxy.cfg")
	if err := os.WriteFile(configFile, []byte(sb.String()), 0644); err != nil {
		return nil, err
	}

	// Create HAProxy container
	container, err := docker.NewContainer(ctx, lbName, &docker.ContainerArgs{
		Image: pulumi.String("haproxy:alpine"),
		Name:  pulumi.String(lbName),
		NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
			&docker.ContainerNetworksAdvancedArgs{Name: pulumi.String(networkName)},
		},
		Ports: docker.ContainerPortArray{
			&docker.ContainerPortArgs{Internal: pulumi.Int(6443), External: pulumi.Int(6443)},
			&docker.ContainerPortArgs{Internal: pulumi.Int(50000), External: pulumi.Int(50000)},
			&docker.ContainerPortArgs{Internal: pulumi.Int(80), External: pulumi.Int(80)},
			&docker.ContainerPortArgs{Internal: pulumi.Int(443), External: pulumi.Int(443)},
		},
		Volumes: docker.ContainerVolumeArray{
			&docker.ContainerVolumeArgs{
				HostPath:      pulumi.String(configFile),
				ContainerPath: pulumi.String("/usr/local/etc/haproxy/haproxy.cfg"),
				ReadOnly:      pulumi.Bool(true),
			},
		},
		Restart: pulumi.String("unless-stopped"),
	})

	if err != nil {
		return nil, err
	}

	p.lbContainer = container
	return container, nil
}

func (p *DockerProvider) createContainer(ctx *pulumi.Context, nodeName string, talosVersion string, networks []string) (*docker.Container, error) {
	image := fmt.Sprintf("ghcr.io/siderolabs/talos:%s", talosVersion)

	networkArgs := docker.ContainerNetworksAdvancedArray{}
	for _, net := range networks {
		networkArgs = append(networkArgs, &docker.ContainerNetworksAdvancedArgs{
			Name: pulumi.String(net),
		})
	}

	return docker.NewContainer(ctx, nodeName, &docker.ContainerArgs{
		Image: pulumi.String(image),
		Name:  pulumi.String(nodeName),
		Volumes: docker.ContainerVolumeArray{
			// System volumes
			&docker.ContainerVolumeArgs{HostPath: pulumi.String("/dev"), ContainerPath: pulumi.String("/dev")},
			&docker.ContainerVolumeArgs{HostPath: pulumi.String("/run/udev"), ContainerPath: pulumi.String("/run/udev"), ReadOnly: pulumi.Bool(true)},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/system/state")},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/var")},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/etc/cni")},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/etc/kubernetes")},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/usr/libexec/kubernetes")},
			&docker.ContainerVolumeArgs{ContainerPath: pulumi.String("/opt")},
		},
		Tmpfs: pulumi.StringMap{
			"/run":    pulumi.String("rw"),
			"/system": pulumi.String("rw"),
			"/tmp":    pulumi.String("rw"),
		},
		CgroupnsMode:     pulumi.String("private"),
		ReadOnly:         pulumi.Bool(true),
		Privileged:       pulumi.Bool(true),
		Envs:             pulumi.StringArray{pulumi.String("PLATFORM=container")},
		NetworksAdvanced: networkArgs,
		Restart:          pulumi.String("unless-stopped"),
	})
}

func (p *DockerProvider) transformConfig(config pulumi.StringOutput) pulumi.StringOutput {
	return config.ApplyT(func(config string) (string, error) {
		var data map[string]interface{}
		if err := yaml.Unmarshal([]byte(config), &data); err != nil {
			return "", err
		}

		appendUnique := func(slice []interface{}, item string) []interface{} {
			for _, s := range slice {
				if s == item {
					return slice
				}
			}
			return append(slice, item)
		}

		if machineData, ok := data["machine"].(map[string]interface{}); ok {
			delete(machineData, "install")
			var certSANs []interface{}
			if existing, ok := machineData["certSANs"].([]interface{}); ok {
				certSANs = existing
			}
			machineData["certSANs"] = appendUnique(certSANs, "127.0.0.1")
		}

		if cluster, ok := data["cluster"].(map[string]interface{}); ok {
			if apiServer, ok := cluster["apiServer"].(map[string]interface{}); ok {
				var certSANs []interface{}
				if existing, ok := apiServer["certSANs"].([]interface{}); ok {
					certSANs = existing
				}
				apiServer["certSANs"] = appendUnique(certSANs, "127.0.0.1")
			}

			// Disable default CNI (Flannel) to allow Cilium installation
			if network, ok := cluster["network"].(map[string]interface{}); ok {
				if cni, ok := network["cni"].(map[string]interface{}); ok {
					cni["name"] = "none"
				} else {
					network["cni"] = map[string]interface{}{
						"name": "none",
					}
				}
			} else {
				cluster["network"] = map[string]interface{}{
					"cni": map[string]interface{}{
						"name": "none",
					},
				}
			}

			// Disable kube-proxy to avoid conflict with Cilium kubeProxyReplacement
			if proxy, ok := cluster["proxy"].(map[string]interface{}); ok {
				proxy["disabled"] = true
			} else {
				cluster["proxy"] = map[string]interface{}{
					"disabled": true,
				}
			}
		}

		out, err := yaml.Marshal(data)
		if err != nil {
			return "", err
		}
		return string(out), nil
	}).(pulumi.StringOutput)
}
