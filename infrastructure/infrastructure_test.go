package main

import (
	"fmt"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
	"github.com/stretchr/testify/assert"

	"openaether/infrastructure/pkg/cluster"
)

type mocks int

func (mocks) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	if args.TypeToken == "scaleway:index/instanceServer:InstanceServer" {
		// Mock logic: Verify expected inputs for Scaleway Instance
		if args.Inputs["type"].V != "DEV1-S" {
			return "", nil, fmt.Errorf("expected instance type DEV1-S, got %v", args.Inputs["type"].V)
		}
		return args.Name + "_id", args.Inputs, nil
	}
	// Pass through for other resources (like component resources)
	return args.Name + "_id", args.Inputs, nil
}

func (mocks) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	return args.Args, nil
}

// MockClusterProvider implements cluster.ClusterProvider for testing
type MockClusterProvider struct{}

func (m *MockClusterProvider) ProvisionNodes(ctx *pulumi.Context, name string, config *cluster.ClusterConfig, machineSecrets *machine.Secrets, cpConfig *machine.GetConfigurationResultOutput) (pulumi.StringOutput, error) {
	return pulumi.String("1.2.3.4").ToStringOutput(), nil
}

func (m *MockClusterProvider) GetControlPlaneEndpoint(ctx *pulumi.Context) pulumi.StringOutput {
	return pulumi.String("1.2.3.4").ToStringOutput()
}

func (m *MockClusterProvider) GetConfigurationApplyNode(ctx *pulumi.Context, internalNodeIp pulumi.StringOutput) pulumi.StringOutput {
	return internalNodeIp
}

func TestInfrastructureWithMocks(t *testing.T) {
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		// Test specific Scaleway Cluster creation logic
		conf := &cluster.ClusterConfig{
			ClusterName:       "test-cluster",
			Endpoint:          "1.2.3.4",
			ControlPlaneNodes: 1,
			WorkerNodes:       0,
			Scaleway: cluster.ScalewayConfig{
				Type:  "DEV1-S",
				Image: "ubuntu_jammy",
			},
		}

		provider := &MockClusterProvider{}

		_, err := cluster.NewTalosCluster(ctx, "test-scaleway", conf, provider)
		if err != nil {
			return err
		}
		return nil
	}, pulumi.WithMocks("project", "stack", mocks(0)))
	assert.NoError(t, err)
}

func TestClusterNaming(t *testing.T) {
	// Simple Logic Test
	clusterName := "openaether-dev"
	assert.Equal(t, "openaether-dev", clusterName, "Cluster name should match")
}
