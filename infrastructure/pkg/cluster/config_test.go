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
	assert.Equal(t, "127.0.0.1", config.Endpoint)
	assert.Equal(t, 1, config.ControlPlaneNodes)
	assert.Equal(t, 1, config.WorkerNodes)
	assert.Equal(t, DefaultDockerNetwork, config.Docker.NetworkName)
	assert.Equal(t, DefaultScalewayImage, config.Scaleway.Image)
	assert.Equal(t, DefaultScalewayType, config.Scaleway.Type)
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
	assert.Equal(t, "DEV1-L", config.Scaleway.Type)
}
