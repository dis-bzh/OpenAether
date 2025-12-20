package main

import (
	"openaether/infrastructure/pkg/cluster"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Example: Deploy a local "Docker" backed Talos cluster (Simulation)
		// Switch "docker" to "scaleway" to deploy to cloud (requires credentials).
		localCluster, err := cluster.NewTalosCluster(ctx, "local-dev-cluster", &cluster.TalosClusterArgs{
			ControlPlaneNodes: 1,
			WorkerNodes:       1,
			CloudProvider:     "docker", // Change to "scaleway" or "ovh" for production
			ClusterName:       "openaether-local",
			Endpoint:          "127.0.0.1",
		})
		if err != nil {
			return err
		}

		ctx.Export("kubeconfig", localCluster.Kubeconfig)
		ctx.Export("status", pulumi.String("provisioned"))

		return nil
	})
}
