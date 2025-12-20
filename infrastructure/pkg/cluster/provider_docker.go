package cluster

import (
	"fmt"

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

func (p *DockerProvider) ProvisionNodes(ctx *pulumi.Context, name string, config *ClusterConfig, machineSecrets *machine.Secrets, cpConfig *machine.GetConfigurationResultOutput) (pulumi.StringOutput, error) {
	networkName := config.Docker.NetworkName

	// Ensure the network exists
	_, err := docker.NewNetwork(ctx, networkName, &docker.NetworkArgs{
		Name:           pulumi.String(networkName),
		Driver:         pulumi.String("bridge"),
		CheckDuplicate: pulumi.Bool(true),
	})
	if err != nil {
		return pulumi.StringOutput{}, err
	}

	var firstNodeIp pulumi.StringOutput

	// Provision Control Plane Nodes on Docker
	for i := 0; i < config.ControlPlaneNodes; i++ {
		nodeName := fmt.Sprintf("%s-cp-%d", name, i)

		// Create the container
		container, err := p.createContainer(ctx, nodeName, config.TalosVersion, networkName)
		if err != nil {
			return pulumi.StringOutput{}, err
		}

		// Transform the config to remove "install" section explicitly and add certSANs for localhost access
		containerConfig := p.transformConfig(cpConfig.MachineConfiguration())

		// Apply Configuration to the Node
		// Targeted to localhost because ports are mapped
		_, err = machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-apply", nodeName), &machine.ConfigurationApplyArgs{
			ClientConfiguration:       machineSecrets.ClientConfiguration,
			MachineConfigurationInput: containerConfig,
			Node:                      pulumi.String("127.0.0.1"), // Targeting localhost for Setup
			Endpoint:                  pulumi.String("127.0.0.1"),
		}, pulumi.Parent(container), pulumi.DependsOn([]pulumi.Resource{container}))
		if err != nil {
			return pulumi.StringOutput{}, err
		}

		if i == 0 {
			// For Docker local, we return localhost as the "IP" to bootstrap against, because we are outside the network
			firstNodeIp = pulumi.String("127.0.0.1").ToStringOutput()
		}
	}

	return firstNodeIp, nil
}

func (p *DockerProvider) createContainer(ctx *pulumi.Context, nodeName string, talosVersion string, networkName string) (*docker.Container, error) {
	image := fmt.Sprintf("ghcr.io/siderolabs/talos:%s", talosVersion)

	return docker.NewContainer(ctx, nodeName, &docker.ContainerArgs{
		Image: pulumi.String(image),
		Name:  pulumi.String(nodeName),
		Volumes: docker.ContainerVolumeArray{
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
		CgroupnsMode: pulumi.String("private"),
		ReadOnly:     pulumi.Bool(true),
		Privileged:   pulumi.Bool(true),
		Envs: pulumi.StringArray{
			pulumi.String("PLATFORM=container"),
		},
		NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
			&docker.ContainerNetworksAdvancedArgs{
				Name: pulumi.String(networkName),
			},
		},
		Ports: docker.ContainerPortArray{
			&docker.ContainerPortArgs{Internal: pulumi.Int(6443), External: pulumi.Int(6443)},
			&docker.ContainerPortArgs{Internal: pulumi.Int(50000), External: pulumi.Int(50000)},
		},
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
