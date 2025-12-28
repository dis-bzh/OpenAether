package cluster

import (
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestLoadClusterConfigFromEnv_Defaults(t *testing.T) {
	// Ensure no env vars interfere
	os.Clearenv()

	config := LoadClusterConfigFromEnv()

	assert.Equal(t, DefaultClusterName, config.ClusterName)
	assert.Equal(t, DefaultKubernetesVersion, config.KubernetesVersion)
	assert.Equal(t, DefaultTalosVersion, config.TalosVersion)
	// Endpoint is now internal LB name for Docker
	assert.Equal(t, "openaether-local-lb", config.Endpoint)
	assert.Equal(t, "127.0.0.1", config.PublicEndpoint)
	// Defaults changed to 3 CPs for HA and 2 workers for multi-cloud simulation
	assert.Equal(t, 3, config.ControlPlaneNodes)
	assert.Equal(t, 2, config.WorkerNodes)
	assert.Equal(t, DefaultDockerNetwork, config.Docker.NetworkName)
	assert.Equal(t, "DEV1-M", config.Scaleway.InstanceType)
	// WireGuard enabled by default
	assert.True(t, config.EnableWireGuard)
}

func TestLoadClusterConfigFromEnv_Custom(t *testing.T) {
	os.Setenv("CLUSTER_NAME", "custom-cluster")
	os.Setenv("KUBERNETES_VERSION", "v1.99.0")
	os.Setenv("CONTROL_PLANE_NODES", "3")
	os.Setenv("DOCKER_NETWORK_NAME", "custom-net")
	os.Setenv("SCW_INSTANCE_TYPE", "DEV1-L")

	defer os.Clearenv()

	config := LoadClusterConfigFromEnv()

	assert.Equal(t, "custom-cluster", config.ClusterName)
	assert.Equal(t, "v1.99.0", config.KubernetesVersion)
	assert.Equal(t, 3, config.ControlPlaneNodes)
	assert.Equal(t, "custom-net", config.Docker.NetworkName)
	assert.Equal(t, "DEV1-L", config.Scaleway.InstanceType)
}

func TestNodeDistribution_Parsing(t *testing.T) {
	os.Clearenv()
	os.Setenv("NODE_DISTRIBUTION", "docker:2:3,ovh:1:2")
	defer os.Clearenv()

	config := LoadClusterConfigFromEnv()

	assert.True(t, config.IsMultiProvider())
	assert.Len(t, config.Nodes, 2)
	assert.Equal(t, "docker", config.Nodes[0].Provider)
	assert.Equal(t, 2, config.Nodes[0].ControlPlanes)
	assert.Equal(t, 3, config.Nodes[0].Workers)
	assert.Equal(t, "ovh", config.Nodes[1].Provider)
	assert.Equal(t, 3, config.TotalControlPlanes())
	assert.Equal(t, 5, config.TotalWorkers())
}

func TestNodeDistribution_MalformedInput(t *testing.T) {
	os.Clearenv()
	os.Setenv("NODE_DISTRIBUTION", "invalid,docker:1")
	defer os.Clearenv()

	config := LoadClusterConfigFromEnv()

	// Should skip malformed entries
	assert.Len(t, config.Nodes, 0)
}

func TestClusterConfig_Helpers(t *testing.T) {
	os.Clearenv()
	os.Setenv("NODE_DISTRIBUTION", "ovh:1:2,scaleway:1:1,outscale:1:0")
	defer os.Clearenv()

	config := LoadClusterConfigFromEnv()

	providers := config.GetProvidersUsed()
	assert.Len(t, providers, 3)
	assert.Contains(t, providers, "ovh")
	assert.Contains(t, providers, "scaleway")
	assert.Contains(t, providers, "outscale")

	// String representation
	str := config.String()
	assert.Contains(t, str, "multi-provider")
	assert.Contains(t, str, "ovh:1CP+2W")
}
