package main

import (
	"openaether/infrastructure/pkg/cluster"
	"os"

	"github.com/joho/godotenv"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	// NOTE: Environment variables are now loaded by Taskfile.yml via dotenv
	// This allows multi-environment support (local, test, staging, prod)
	// godotenv.Load() is kept as fallback for direct `go run` or `pulumi up`
	_ = godotenv.Load()

	pulumi.Run(func(ctx *pulumi.Context) error {
		// Load config from Environment
		config := cluster.LoadClusterConfigFromEnv()

		// Determine which provider(s) to use
		var provider cluster.ClusterProvider
		cloudProvider := os.Getenv("CLOUD_PROVIDER")

		// If multi-provider mode, the provider is used only for fallback
		// The actual provisioning happens via ProviderRegistry in talos.go
		if !config.IsMultiProvider() {
			// Single-provider mode (legacy)
			switch cloudProvider {
			case "ovh":
				// TODO: provider = cluster.NewOvhProvider()
				ctx.Log.Warn("OVH provider not yet implemented, falling back to Docker", nil)
				provider = cluster.NewDockerProvider()
			case "scaleway":
				// TODO: provider = cluster.NewScalewayProvider()
				ctx.Log.Warn("Scaleway provider not yet implemented, falling back to Docker", nil)
				provider = cluster.NewDockerProvider()
			case "outscale":
				provider = cluster.NewOutscaleProvider()
			case "docker":
				fallthrough
			default:
				if cloudProvider != "docker" && cloudProvider != "" {
					_ = ctx.Log.Warn("Unknown Cloud Provider: "+cloudProvider+". Defaulting to Docker.", nil)
				}
				provider = cluster.NewDockerProvider()
			}
		} else {
			// Multi-provider mode: use Docker as the default single-provider fallback
			provider = cluster.NewDockerProvider()
			ctx.Log.Info("Multi-provider mode enabled: "+config.String(), nil)
		}

		ctx.Export("cloud_provider", pulumi.String(cloudProvider))
		ctx.Export("multi_provider_mode", pulumi.Bool(config.IsMultiProvider()))
		ctx.Export("node_distribution", pulumi.String(config.String()))

		// Deploy the Talos Cluster
		talosCluster, err := cluster.NewTalosCluster(ctx, config.ClusterName, config, provider)
		if err != nil {
			return err
		}

		ctx.Export("kubeconfig", talosCluster.Kubeconfig)
		ctx.Export("talosconfig", talosCluster.Talosconfig)
		ctx.Export("status", pulumi.String("provisioned"))
		ctx.Export("total_nodes", pulumi.Int(config.TotalControlPlanes()+config.TotalWorkers()))

		return nil
	})
}
