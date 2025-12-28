// Package components provides Kubernetes component deployments via Pulumi.
package components

import (
	"openaether/infrastructure/pkg/helm"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	"github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// CiliumConfig holds configuration for Cilium CNI deployment.
type CiliumConfig struct {
	// Version of Cilium to install
	Version string
	// K8sServiceHost is the Kubernetes API server hostname (static, for Docker/local)
	K8sServiceHost string
	// K8sServiceHostDynamic is the Kubernetes API server hostname (dynamic output, for cloud)
	K8sServiceHostDynamic pulumi.StringOutput
	// K8sServicePort is the Kubernetes API server port
	K8sServicePort int
	// EnableWireGuard enables WireGuard encryption for cross-cloud traffic
	EnableWireGuard bool
	// EnableHubble enables Hubble observability
	EnableHubble bool
}

// DefaultCiliumConfig returns default Cilium configuration.
func DefaultCiliumConfig() CiliumConfig {
	return CiliumConfig{
		Version:         "1.14.5",
		K8sServiceHost:  "openaether-local-lb",
		K8sServicePort:  6443,
		EnableWireGuard: true,
		EnableHubble:    true,
	}
}

// WaitForClusterReady creates a command that waits for the Kubernetes API to be ready.
// This is essential because Talos takes time to bootstrap the cluster after node creation.
func WaitForClusterReady(
	ctx *pulumi.Context,
	name string,
	kubeconfig pulumi.StringOutput,
	opts ...pulumi.ResourceOption,
) (*local.Command, error) {
	// Write kubeconfig to temp file and poll API server
	// The command retries until the API server responds
	waitScript := `
set -e
KUBECONFIG_FILE=$(mktemp)
echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_FILE"
trap "rm -f $KUBECONFIG_FILE" EXIT

echo "Waiting for Kubernetes API server to be ready..."
for i in $(seq 1 60); do
    if kubectl --kubeconfig "$KUBECONFIG_FILE" cluster-info > /dev/null 2>&1; then
        echo "Kubernetes API server is responding!"
        break
    fi
    echo "Attempt $i/60: API not ready yet, waiting 5 seconds..."
    sleep 5
done

# Extra wait for API to stabilize and nodes to be visible
echo "Waiting for nodes to be visible..."
for i in $(seq 1 30); do
    NODE_COUNT=$(kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$NODE_COUNT" -gt "0" ]; then
        echo "Found $NODE_COUNT node(s)!"
        kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes
        echo "API is stable, proceeding..."
        exit 0
    fi
    echo "Attempt $i/30: No nodes visible yet, waiting 5 seconds..."
    sleep 5
done

echo "ERROR: No nodes became visible in time"
exit 1
`

	return local.NewCommand(ctx, name, &local.CommandArgs{
		Create: pulumi.String("bash -c '" + waitScript + "'"),
		Environment: pulumi.StringMap{
			"KUBECONFIG_CONTENT": kubeconfig,
		},
	}, opts...)
}

// DeployCilium deploys Cilium CNI using Helm.
// It waits for the Kubernetes cluster to be ready before deploying.
func DeployCilium(
	ctx *pulumi.Context,
	name string,
	cfg CiliumConfig,
	kubeconfig pulumi.StringOutput,
	kubeProvider *kubernetes.Provider,
	waitCmd *local.Command,
	opts ...pulumi.ResourceOption,
) (*CiliumDeployment, error) {

	// Determine the k8s API server host
	// For cloud deployments, use the dynamic endpoint
	var k8sHostValue interface{}
	if cfg.K8sServiceHostDynamic != (pulumi.StringOutput{}) {
		// Use dynamic host (pulumi.StringOutput) for cloud deployments
		k8sHostValue = cfg.K8sServiceHostDynamic
	} else {
		// Use static host (string) for local/docker deployments
		k8sHostValue = cfg.K8sServiceHost
	}

	// Build Cilium values
	values := map[string]interface{}{
		// Core configuration
		"kubeProxyReplacement": true,
		"k8sServiceHost":       k8sHostValue,
		"k8sServicePort":       cfg.K8sServicePort,

		// BPF configuration for container environment
		"bpf": map[string]interface{}{
			"masquerade": true,
		},
		"ipam": map[string]interface{}{
			"mode": "kubernetes",
		},

		// Operator configuration
		"operator": map[string]interface{}{
			"replicas": 1,
		},

		// Security context for Docker/container environment
		"securityContext": map[string]interface{}{
			"privileged": true,
		},

		// Enable rollout restart when configmap changes
		"rollOutCiliumPods": true,
	}

	// Enable WireGuard encryption for cross-cloud
	if cfg.EnableWireGuard {
		values["encryption"] = map[string]interface{}{
			"enabled": true,
			"type":    "wireguard",
		}
	}

	// Enable Hubble observability
	if cfg.EnableHubble {
		values["hubble"] = map[string]interface{}{
			"enabled": true,
			"relay": map[string]interface{}{
				"enabled": true,
			},
			"ui": map[string]interface{}{
				"enabled": true,
			},
		}
	}

	// Add DependsOn waitCmd to ensure cluster is ready
	allOpts := append(opts, pulumi.DependsOn([]pulumi.Resource{waitCmd}))

	release, err := helm.NewRelease(ctx, name, helm.ReleaseConfig{
		Name:            "cilium",
		Namespace:       "kube-system",
		Chart:           "cilium",
		Version:         cfg.Version,
		Repository:      "https://helm.cilium.io/",
		Values:          values,
		CreateNamespace: false, // kube-system already exists
		Wait:            false, // Cilium takes time to start
		Timeout:         600,   // 10 minutes
	}, kubeProvider, allOpts...)

	if err != nil {
		return nil, err
	}

	return &CiliumDeployment{
		Release: release,
	}, nil
}

// CiliumDeployment represents a deployed Cilium CNI.
type CiliumDeployment struct {
	Release pulumi.Resource
}
