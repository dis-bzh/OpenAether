package main

import (
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
	"github.com/stretchr/testify/assert"

	"openaether/infrastructure/pkg/cluster"
)

type mocks int

func (mocks) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	// Pass through for all resources
	return args.Name + "_id", args.Inputs, nil
}

func (mocks) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	return args.Args, nil
}

// MockClusterProvider implements cluster.ClusterProvider for testing
type MockClusterProvider struct{}

func (m *MockClusterProvider) Name() string {
	return "mock"
}

func (m *MockClusterProvider) GetPublicEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return pulumi.String("127.0.0.1").ToStringOutput()
}

func (m *MockClusterProvider) ConfigureNetworking(ctx *pulumi.Context, name string, config *cluster.ClusterConfig) error {
	return nil
}

func (m *MockClusterProvider) ProvisionNodes(
	ctx *pulumi.Context,
	name string,
	config *cluster.ClusterConfig,
	distribution cluster.NodeDistribution,
	globalNodeIndex int,
	machineSecrets *machine.Secrets,
	cpConfig *machine.GetConfigurationResultOutput,
	workerConfig *machine.GetConfigurationResultOutput,
) ([]cluster.ProvisionedNode, pulumi.StringOutput, error) {
	return []cluster.ProvisionedNode{
		{
			Name:       name + "-cp-0",
			Role:       "controlplane",
			Provider:   "mock",
			InternalIP: pulumi.String("1.2.3.4").ToStringOutput(),
			PublicIP:   pulumi.String("1.2.3.4").ToStringOutput(),
		},
	}, pulumi.String("1.2.3.4").ToStringOutput(), nil
}

func TestClusterConfigFromEnv(t *testing.T) {
	// Test default config
	config := cluster.LoadClusterConfigFromEnv()
	assert.Equal(t, "openaether", config.ClusterName)
	assert.Equal(t, false, config.IsMultiProvider())
	assert.Equal(t, 3, config.TotalControlPlanes())
	assert.Equal(t, 2, config.TotalWorkers())
}

func TestNodeDistributionParsing(t *testing.T) {
	t.Setenv("NODE_DISTRIBUTION", "docker:1:2,ovh:2:1")

	config := cluster.LoadClusterConfigFromEnv()
	assert.Equal(t, true, config.IsMultiProvider())
	assert.Equal(t, 3, config.TotalControlPlanes()) // 1 + 2
	assert.Equal(t, 3, config.TotalWorkers())       // 2 + 1
	assert.Len(t, config.Nodes, 2)
	assert.Equal(t, "docker", config.Nodes[0].Provider)
	assert.Equal(t, "ovh", config.Nodes[1].Provider)
}

func TestClusterConfigString(t *testing.T) {
	t.Setenv("NODE_DISTRIBUTION", "ovh:1:2,scaleway:1:1,outscale:1:0")

	config := cluster.LoadClusterConfigFromEnv()
	expected := "multi-provider: [ovh:1CP+2W, scaleway:1CP+1W, outscale:1CP+0W]"
	assert.Equal(t, expected, config.String())
}

func TestProviderRegistry(t *testing.T) {
	registry := cluster.NewProviderRegistry()

	// Docker should be available
	docker, ok := registry.Get("docker")
	assert.True(t, ok)
	assert.Equal(t, "docker", docker.Name())

	// Unknown provider should return false
	_, ok = registry.Get("unknown")
	assert.False(t, ok)
}

func TestMockProviderInterface(t *testing.T) {
	mock := &MockClusterProvider{}
	assert.Equal(t, "mock", mock.Name())
}
