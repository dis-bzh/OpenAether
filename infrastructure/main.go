package main

import (
	"openaether/infrastructure/pkg/cluster"
	"os"

	"github.com/joho/godotenv"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	// Load .env.local first for local overrides (ignored if missing)
	_ = godotenv.Load(".env.local")
	// Load .env file (defaults)
	_ = godotenv.Load()

	pulumi.Run(func(ctx *pulumi.Context) error {
		// Load config from Environment
		config := cluster.LoadClusterConfigFromEnv()

		// Select Provider based on CLOUD_PROVIDER env var
		var provider cluster.ClusterProvider
		cloudProvider := os.Getenv("CLOUD_PROVIDER")

		switch cloudProvider {
		case "scaleway":
			provider = cluster.NewScalewayProvider()
		case "docker":
			fallthrough
		default:
			if cloudProvider != "docker" && cloudProvider != "" {
				_ = ctx.Log.Warn("Unknown Cloud Provider: "+cloudProvider+". Defaulting to Docker.", nil)
			}
			provider = cluster.NewDockerProvider()
		}

		ctx.Export("cloud_provider", pulumi.String(cloudProvider))

		// Deploy the Talos Cluster using the specific provider
		talosCluster, err := cluster.NewTalosCluster(ctx, config.ClusterName, config, provider)
		if err != nil {
			return err
		}

		ctx.Export("kubeconfig", talosCluster.Kubeconfig)
		ctx.Export("talosconfig", talosCluster.Talosconfig)
		ctx.Export("status", pulumi.String("provisioned"))

		return nil
	})
}
