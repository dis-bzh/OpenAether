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
	// We can store provider specific state here if needed
}

func NewDockerProvider() *DockerProvider {
	return &DockerProvider{}
}

func (p *DockerProvider) GetControlPlaneEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return pulumi.String("127.0.0.1").ToStringOutput()
}

func (p *DockerProvider) GetConfigurationApplyNode(ctx *pulumi.Context, internalNodeIp pulumi.StringOutput) pulumi.StringOutput {
	// For local Docker, we apply config to localhost because the ports are forwarded.
	return pulumi.String("127.0.0.1").ToStringOutput()
}

func (p *DockerProvider) ProvisionNodes(ctx *pulumi.Context, name string, config *ClusterConfig, machineSecrets *machine.Secrets, cpConfig *machine.GetConfigurationResultOutput, workerConfig *machine.GetConfigurationResultOutput) (pulumi.StringOutput, error) {
	internetNetworkName := config.Docker.NetworkName + "-internet"

	// 1. Create the "Internet" Network (Shared)
	// This network simulates the public internet. All nodes technically have an interface here to talk to "each other" via public IPs if needed,
	// or at least to be reachable from the host.
	_, err := docker.NewNetwork(ctx, internetNetworkName, &docker.NetworkArgs{
		Name:           pulumi.String(internetNetworkName),
		Driver:         pulumi.String("bridge"),
		CheckDuplicate: pulumi.Bool(true),
	})
	if err != nil {
		return pulumi.StringOutput{}, err
	}

	// 2. Create "Cloud" Networks (Private VPCs)
	// e.g. openaether-cloud-a, openaether-cloud-b
	for _, cloudName := range config.Docker.Clouds {
		netName := config.Docker.NetworkName + "-" + cloudName
		_, err := docker.NewNetwork(ctx, netName, &docker.NetworkArgs{
			Name:           pulumi.String(netName),
			Driver:         pulumi.String("bridge"),
			CheckDuplicate: pulumi.Bool(true),
			Internal:       pulumi.Bool(true), // Internal to simulate limited access? Or just bridge. Let's keep bridge for now but separate.
		})
		if err != nil {
			return pulumi.StringOutput{}, err
		}
	}

	var firstNodeIp pulumi.StringOutput

	// Helper to create nodes
	createNode := func(role string, index int, totalCount int, configOutput *machine.GetConfigurationResultOutput, exposePorts bool) (pulumi.StringOutput, error) {
		nodeName := fmt.Sprintf("%s-%s-%d", name, role, index)
		// Distribution text: Cloud A, Cloud B...
		// cloudIndex := index % len(config.Docker.Clouds)
		// cloudName := config.Docker.Clouds[cloudIndex]
		// cloudNetworkName := config.Docker.NetworkName + "-" + cloudName
		// For now, simplificy: Just use the Internet network for Apply IP lookup.
		// All nodes are on Internet network.

		// Create the container attached to Internet AND its specific Cloud
		cloudIndex := index % len(config.Docker.Clouds)
		cloudName := config.Docker.Clouds[cloudIndex]
		cloudNetworkName := config.Docker.NetworkName + "-" + cloudName

		networks := []string{internetNetworkName, cloudNetworkName}

		container, err := p.createContainer(ctx, nodeName, config.TalosVersion, networks, exposePorts)
		if err != nil {
			return pulumi.StringOutput{}, err
		}

		// Retrieve IP address from the Internet Network
		// Retrieve IP address from the Internet Network
		// We need to look up the NetworkData for the specific network name
		containerInternalIp := container.NetworkDatas.ApplyT(func(datas []docker.ContainerNetworkData) (string, error) {
			for _, data := range datas {
				// NetworkName is *string, IpAddress is *string
				if data.NetworkName != nil && *data.NetworkName == internetNetworkName && data.IpAddress != nil && *data.IpAddress != "" {
					return *data.IpAddress, nil
				}
			}
			// Fallback: If not found, try to find ANY ip.
			if len(datas) > 0 && datas[0].IpAddress != nil && *datas[0].IpAddress != "" {
				return *datas[0].IpAddress, nil
			}
			return "", fmt.Errorf("could not find IP address for node %s", nodeName)
		}).(pulumi.StringOutput)

		// Transform config
		containerConfig := p.transformConfig(configOutput.MachineConfiguration())

		// Apply Configuration
		// We use the Container IP to reach the node from the Host (Linux specific, or requires routing)
		// Since user is on Linux, this works.
		_, err = machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-apply", nodeName), &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: containerConfig,
			Node:                      containerInternalIp,
			Endpoint:                  containerInternalIp, // The temporary endpoint for the Apply command
		}, pulumi.Parent(container), pulumi.DependsOn([]pulumi.Resource{container}))
		if err != nil {
			return pulumi.StringOutput{}, err
		}

		return containerInternalIp, nil
	}

	// 3. Provision Load Balancer (HAProxy)
	// Must happen before/parallel to nodes so DNS resolution works or retries
	_, err = p.createLoadBalancer(ctx, name, config, internetNetworkName)
	if err != nil {
		return pulumi.StringOutput{}, err
	}

	// 4. Provision Control Plane Nodes
	for i := 0; i < config.ControlPlaneNodes; i++ {
		// All nodes are internal now. No exposed ports.
		// Access is strictly through the Load Balancer.
		expose := false
		ip, err := createNode("cp", i, config.ControlPlaneNodes, cpConfig, expose)
		if err != nil {
			return pulumi.StringOutput{}, err
		}
		if i == 0 {
			firstNodeIp = ip
		}
	}

	// 5. Provision Worker Nodes
	for i := 0; i < config.WorkerNodes; i++ {
		_, err := createNode("worker", i, config.WorkerNodes, workerConfig, false)
		if err != nil {
			return pulumi.StringOutput{}, err
		}
	}

	return firstNodeIp, nil
}

func (p *DockerProvider) createLoadBalancer(ctx *pulumi.Context, name string, config *ClusterConfig, networkName string) (*docker.Container, error) {
	lbName := "openaether-local-lb"

	// 1. Generate HAProxy Config
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
	for i := 0; i < config.ControlPlaneNodes; i++ {
		nodeName := fmt.Sprintf("%s-cp-%d", name, i)
		sb.WriteString(fmt.Sprintf("    server cp-%d %s:6443 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend talos_api
    bind *:50000
    default_backend talos_api_backend

backend talos_api_backend
`)
	for i := 0; i < config.ControlPlaneNodes; i++ {
		nodeName := fmt.Sprintf("%s-cp-%d", name, i)
		sb.WriteString(fmt.Sprintf("    server cp-%d %s:50000 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend ingress_http
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
`)
	for i := 0; i < config.WorkerNodes; i++ {
		nodeName := fmt.Sprintf("%s-worker-%d", name, i)
		sb.WriteString(fmt.Sprintf("    server worker-%d %s:80 check\n", i, nodeName))
	}

	sb.WriteString(`
frontend ingress_https
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
`)
	for i := 0; i < config.WorkerNodes; i++ {
		nodeName := fmt.Sprintf("%s-worker-%d", name, i)
		sb.WriteString(fmt.Sprintf("    server worker-%d %s:443 check\n", i, nodeName))
	}

	// 2. Write Config to Host (project dir/haproxy/haproxy.cfg)
	wd, _ := os.Getwd()
	configDir := filepath.Join(wd, "haproxy")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return nil, err
	}
	configFile := filepath.Join(configDir, "haproxy.cfg")
	if err := os.WriteFile(configFile, []byte(sb.String()), 0644); err != nil {
		return nil, err
	}

	// 3. Create HAProxy Container
	return docker.NewContainer(ctx, lbName, &docker.ContainerArgs{
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
}

func (p *DockerProvider) createContainer(ctx *pulumi.Context, nodeName string, talosVersion string, networks []string, exposePorts bool) (*docker.Container, error) {
	image := fmt.Sprintf("ghcr.io/siderolabs/talos:%s", talosVersion)

	networkArgs := docker.ContainerNetworksAdvancedArray{}
	for _, net := range networks {
		networkArgs = append(networkArgs, &docker.ContainerNetworksAdvancedArgs{
			Name: pulumi.String(net),
		})
	}

	var ports docker.ContainerPortArray
	if exposePorts {
		ports = docker.ContainerPortArray{
			&docker.ContainerPortArgs{Internal: pulumi.Int(6443), External: pulumi.Int(6443)},
			&docker.ContainerPortArgs{Internal: pulumi.Int(50000), External: pulumi.Int(50000)},
		}
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
		Ports:            ports,
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

		if machine, ok := data["machine"].(map[string]interface{}); ok {
			delete(machine, "install")
			var certSANs []interface{}
			if existing, ok := machine["certSANs"].([]interface{}); ok {
				certSANs = existing
			}
			machine["certSANs"] = appendUnique(certSANs, "127.0.0.1")
		}

		if cluster, ok := data["cluster"].(map[string]interface{}); ok {
			if apiServer, ok := cluster["apiServer"].(map[string]interface{}); ok {
				var certSANs []interface{}
				if existing, ok := apiServer["certSANs"].([]interface{}); ok {
					certSANs = existing
				}
				apiServer["certSANs"] = appendUnique(certSANs, "127.0.0.1")
			}
		}

		out, err := yaml.Marshal(data)
		if err != nil {
			return "", err
		}
		return string(out), nil
	}).(pulumi.StringOutput)
}
