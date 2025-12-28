package cluster

import (
	"fmt"
	"openaether/infrastructure/pkg/components"
	"openaether/infrastructure/pkg/helm"
	"strings"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	taloscluster "github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

// TalosCluster represents a provisioned Talos Kubernetes cluster.
type TalosCluster struct {
	pulumi.ResourceState
	Kubeconfig  pulumi.StringOutput
	Talosconfig pulumi.StringOutput
	Nodes       []ProvisionedNode
	Cilium      *components.CiliumDeployment
}

// NewTalosCluster creates a new Talos Cluster using one or more Cloud Providers.
// Supports both single-provider mode (legacy) and multi-provider mode.
// Also deploys Cilium CNI after the cluster is bootstrapped.
func NewTalosCluster(ctx *pulumi.Context, name string, config *ClusterConfig, provider ClusterProvider, opts ...pulumi.ResourceOption) (*TalosCluster, error) {
	cluster := &TalosCluster{}
	err := ctx.RegisterComponentResource("openaether:cluster:TalosCluster", name, cluster, opts...)
	if err != nil {
		return nil, err
	}

	// Log cluster configuration
	ctx.Log.Info(fmt.Sprintf("Creating cluster: %s", config.String()), nil)

	// 1. Generate Machine Secrets
	secrets, err := machine.NewSecrets(ctx, name+"-secrets", &machine.SecretsArgs{
		TalosVersion: pulumi.String(config.TalosVersion),
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	// Determine if this is a cloud deployment
	isCloudDeployment := config.IsMultiProvider() ||
		(!strings.Contains(config.Endpoint, "local") && config.Endpoint != "openaether-local-lb")

	// 2. Determine cluster endpoint
	// For Docker: use the configured endpoint (load balancer name)
	// For Cloud: use the first control plane's public IP (pre-allocated in ConfigureNetworking)
	var clusterEndpoint pulumi.StringOutput
	var preConfiguredRegistry *ProviderRegistry

	if isCloudDeployment && config.IsMultiProvider() {
		// Multi-provider cloud mode: configure first provider now to get its pre-allocated IP
		preConfiguredRegistry = NewProviderRegistry()
		if len(config.Nodes) > 0 {
			firstProviderName := config.Nodes[0].Provider
			if firstProvider, ok := preConfiguredRegistry.Get(firstProviderName); ok {
				// Configure networking - this pre-allocates the first CP's public IP
				err := firstProvider.ConfigureNetworking(ctx, name, config)
				if err != nil {
					return nil, err
				}
				// Get the pre-allocated IP for generating Talos configs
				clusterEndpoint = firstProvider.GetPublicEndpoint(ctx)
			}
		}
		if clusterEndpoint == (pulumi.StringOutput{}) {
			clusterEndpoint = pulumi.String(config.Endpoint).ToStringOutput()
		}
	} else if isCloudDeployment {
		// Single cloud provider mode
		err := provider.ConfigureNetworking(ctx, name, config)
		if err != nil {
			return nil, err
		}
		clusterEndpoint = provider.GetPublicEndpoint(ctx)
	} else {
		// Docker local mode: use the configured endpoint (load balancer name)
		clusterEndpoint = pulumi.String(config.Endpoint).ToStringOutput()
	}

	// 3. Talos Config Patches for Cilium
	// Disable kube-proxy (Cilium will replace it with eBPF)
	// Keep Flannel as bootstrap CNI - Cilium will coexist and handle routing
	talosConfigPatches := pulumi.StringArray{
		pulumi.String(`cluster:
  proxy:
    disabled: true
`),
	}

	// 4. Generate Machine Configuration (Control Plane)
	cpConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:       pulumi.String(config.ClusterName),
		MachineType:       pulumi.String("controlplane"),
		ClusterEndpoint:   pulumi.Sprintf("https://%s:6443", clusterEndpoint),
		MachineSecrets:    secrets.MachineSecrets,
		TalosVersion:      pulumi.String(config.TalosVersion),
		KubernetesVersion: pulumi.String(config.KubernetesVersion),
		Docs:              pulumi.Bool(false),
		Examples:          pulumi.Bool(false),
		ConfigPatches:     talosConfigPatches,
	}, pulumi.Parent(cluster))

	// 5. Generate Machine Configuration (Worker)
	workerConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:       pulumi.String(config.ClusterName),
		MachineType:       pulumi.String("worker"),
		ClusterEndpoint:   pulumi.Sprintf("https://%s:6443", clusterEndpoint),
		MachineSecrets:    secrets.MachineSecrets,
		TalosVersion:      pulumi.String(config.TalosVersion),
		KubernetesVersion: pulumi.String(config.KubernetesVersion),
		Docs:              pulumi.Bool(false),
		Examples:          pulumi.Bool(false),
		ConfigPatches:     talosConfigPatches,
	}, pulumi.Parent(cluster))

	var allNodes []ProvisionedNode
	var firstCPIP pulumi.StringOutput

	// 5. Provision nodes based on mode
	if config.IsMultiProvider() {
		// Multi-provider mode: provision nodes across multiple providers
		// Pass the preConfiguredRegistry to avoid duplicate ConfigureNetworking for first provider
		allNodes, firstCPIP, err = provisionMultiProvider(ctx, name, config, secrets, &cpConfig, &workerConfig, preConfiguredRegistry)
		if err != nil {
			return nil, err
		}
		// clusterEndpoint is already set from GetPublicEndpoint earlier
	} else {
		// Single-provider mode (legacy)
		err = provider.ConfigureNetworking(ctx, name, config)
		if err != nil {
			return nil, err
		}

		distribution := NodeDistribution{
			Provider:      provider.Name(),
			ControlPlanes: config.ControlPlaneNodes,
			Workers:       config.WorkerNodes,
		}

		allNodes, firstCPIP, err = provider.ProvisionNodes(
			ctx, name, config, distribution, 0,
			secrets, &cpConfig, &workerConfig,
		)
		if err != nil {
			return nil, err
		}

		// Create Load Balancer for Docker provider
		if dockerProvider, ok := provider.(*DockerProvider); ok {
			_, err = dockerProvider.CreateLoadBalancer(ctx, name, config, allNodes)
			if err != nil {
				return nil, err
			}
		}

		// For non-Docker single provider (cloud), use firstCPIP
		if provider.Name() != "docker" {
			clusterEndpoint = firstCPIP
		}
	}

	cluster.Nodes = allNodes

	// 6. Bootstrap Cluster (first control plane node)
	bootstrap, err := machine.NewBootstrap(ctx, name+"-bootstrap", &machine.BootstrapArgs{
		ClientConfiguration: secrets.ClientConfiguration,
		Node:                firstCPIP,
		Endpoint:            firstCPIP,
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	ctx.Export("clusterInfo", pulumi.Sprintf("Cluster %s: %d CPs, %d Workers", name, config.TotalControlPlanes(), config.TotalWorkers()))

	// 7. Retrieve Kubeconfig - use firstCPIP for cloud, config.PublicEndpoint for docker
	var kubeconfigEndpoint pulumi.StringOutput
	if isCloudDeployment {
		kubeconfigEndpoint = firstCPIP
	} else {
		kubeconfigEndpoint = pulumi.String(config.PublicEndpoint).ToStringOutput()
	}

	kubeconfigRes, err := taloscluster.NewKubeconfig(ctx, name+"-kubeconfig", &taloscluster.KubeconfigArgs{
		ClientConfiguration: taloscluster.KubeconfigClientConfigurationArgs{
			CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
			ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
			ClientKey:         secrets.ClientConfiguration.ClientKey(),
		},
		Node:     firstCPIP,
		Endpoint: kubeconfigEndpoint,
	}, pulumi.Parent(cluster), pulumi.DependsOn([]pulumi.Resource{bootstrap}))
	if err != nil {
		return nil, err
	}

	// Post-process kubeconfig to replace 127.0.0.1 with the actual public IP
	// Talos generates kubeconfig with localhost by default
	cluster.Kubeconfig = pulumi.All(kubeconfigRes.KubeconfigRaw, kubeconfigEndpoint).ApplyT(func(args []interface{}) string {
		kubeconfig := args[0].(string)
		endpoint := args[1].(string)
		// Replace both possible localhost references
		kubeconfig = strings.Replace(kubeconfig, "https://127.0.0.1:6443", "https://"+endpoint+":6443", -1)
		kubeconfig = strings.Replace(kubeconfig, "https://localhost:6443", "https://"+endpoint+":6443", -1)
		return kubeconfig
	}).(pulumi.StringOutput)

	// 8. Talosconfig (simplified format) - with certificate data
	cluster.Talosconfig = pulumi.All(
		config.ClusterName,
		firstCPIP,
		secrets.ClientConfiguration.CaCertificate(),
		secrets.ClientConfiguration.ClientCertificate(),
		secrets.ClientConfiguration.ClientKey(),
	).ApplyT(func(args []interface{}) string {
		clusterName := args[0].(string)
		endpoint := args[1].(string)
		ca := args[2].(string)
		cert := args[3].(string)
		key := args[4].(string)
		return fmt.Sprintf(`context: %s
contexts:
  %s:
    endpoints:
      - %s
    nodes:
      - %s
    ca: %s
    crt: %s
    key: %s
`, clusterName, clusterName, endpoint, endpoint, ca, cert, key)
	}).(pulumi.StringOutput)

	// 9. Create Kubernetes provider for Helm deployments
	kubeProvider, err := helm.NewKubernetesProvider(ctx, name+"-k8s-provider", cluster.Kubeconfig)
	if err != nil {
		return nil, err
	}

	// 10. Wait for cluster to be ready before deploying CNI
	waitCmd, err := components.WaitForClusterReady(ctx, name+"-wait-ready", cluster.Kubeconfig, pulumi.DependsOn([]pulumi.Resource{bootstrap}))
	if err != nil {
		return nil, err
	}

	// 12. Deploy Cilium CNI
	ciliumCfg := components.DefaultCiliumConfig()
	if isCloudDeployment {
		// For cloud, use the first CP's public IP as k8s API server host
		// This is necessary for kubeProxyReplacement mode before CNI is ready
		ciliumCfg.K8sServiceHost = ""
		ciliumCfg.K8sServiceHostDynamic = firstCPIP
	} else {
		ciliumCfg.K8sServiceHost = config.Endpoint
	}
	ciliumCfg.EnableWireGuard = config.EnableWireGuard

	cluster.Cilium, err = components.DeployCilium(ctx, name+"-cilium",
		ciliumCfg,
		cluster.Kubeconfig,
		kubeProvider,
		waitCmd,
		pulumi.Parent(cluster),
	)
	if err != nil {
		return nil, err
	}

	ctx.Export("cilium_version", pulumi.String(ciliumCfg.Version))
	ctx.Export("wireguard_enabled", pulumi.Bool(ciliumCfg.EnableWireGuard))

	return cluster, nil
}

// provisionMultiProvider provisions nodes across multiple providers.
// If preConfiguredRegistry is provided, use it for the first provider (already configured).
func provisionMultiProvider(
	ctx *pulumi.Context,
	name string,
	config *ClusterConfig,
	secrets *machine.Secrets,
	cpConfig *machine.GetConfigurationResultOutput,
	workerConfig *machine.GetConfigurationResultOutput,
	preConfiguredRegistry *ProviderRegistry,
) ([]ProvisionedNode, pulumi.StringOutput, error) {

	// Use pre-configured registry for first provider if available, else create new
	registry := preConfiguredRegistry
	if registry == nil {
		registry = NewProviderRegistry()
	}

	var allNodes []ProvisionedNode
	var firstCPIP pulumi.StringOutput
	globalNodeIndex := 0

	for i, distribution := range config.Nodes {
		provider, ok := registry.Get(distribution.Provider)
		if !ok {
			return nil, pulumi.StringOutput{}, fmt.Errorf("unknown provider: %s", distribution.Provider)
		}

		// Configure networking for this provider
		// Skip first provider if we have a preConfiguredRegistry (already configured)
		if !(preConfiguredRegistry != nil && i == 0) {
			err := provider.ConfigureNetworking(ctx, name, config)
			if err != nil {
				return nil, pulumi.StringOutput{}, err
			}
		}

		// Provision nodes for this provider
		nodes, providerFirstCPIP, err := provider.ProvisionNodes(
			ctx, name, config, distribution, globalNodeIndex,
			secrets, cpConfig, workerConfig,
		)
		if err != nil {
			return nil, pulumi.StringOutput{}, err
		}

		allNodes = append(allNodes, nodes...)

		// Track first CP IP if not set
		if firstCPIP == (pulumi.StringOutput{}) && distribution.ControlPlanes > 0 {
			firstCPIP = providerFirstCPIP
		}

		globalNodeIndex += distribution.ControlPlanes + distribution.Workers
	}

	// For Docker provider, create a unified load balancer
	if len(config.Nodes) > 0 && config.Nodes[0].Provider == "docker" {
		if dockerProvider, ok := registry.Get("docker"); ok {
			if dp, ok := dockerProvider.(*DockerProvider); ok {
				_, err := dp.CreateLoadBalancer(ctx, name, config, allNodes)
				if err != nil {
					return nil, pulumi.StringOutput{}, err
				}
			}
		}
	}

	return allNodes, firstCPIP, nil
}
