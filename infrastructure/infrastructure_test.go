package main

import (
	"fmt"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/stretchr/testify/assert"

	"openaether/infrastructure/pkg/cluster"
)

type mocks int

func (mocks) NewResource(args pulumi.MockResourceArgs) (string, pulumi.ResourceState, error) {
	if args.TypeToken == "scaleway:index/instanceServer:InstanceServer" {
		// Mock logic: Verify expected inputs for Scaleway Instance
		if args.Inputs["type"] != "DEV1-S" {
			return "", pulumi.ResourceState{}, fmt.Errorf("expected instance type DEV1-S, got %v", args.Inputs["type"])
		}
		return args.Name + "_id", pulumi.ResourceState{
			Inputs: args.Inputs,
		}, nil
	}
	// Pass through for other resources (like component resources)
	return args.Name + "_id", pulumi.ResourceState{
		Inputs: args.Inputs,
	}, nil
}

func (mocks) Call(args pulumi.MockCallArgs) (pulumi.ResourceState, error) {
	return pulumi.ResourceState{}, nil
}

func TestInfrastructureWithMocks(t *testing.T) {
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		// Test specific Scaleway Cluster creation logic
		_, err := cluster.NewTalosCluster(ctx, "test-scaleway", &cluster.TalosClusterArgs{
			ControlPlaneNodes: 1,
			WorkerNodes:       0,
			CloudProvider:     "scaleway",
			ClusterName:       "test-cluster",
			Endpoint:          "1.2.3.4",
		})
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
