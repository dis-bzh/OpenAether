package cluster

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Global constants for defaults
const (
	DefaultKubernetesVersion = "v1.32.0"
	DefaultTalosVersion      = "v1.11.6"
	DefaultClusterName       = "openaether"
	DefaultDockerNetwork     = "openaether-net"
	DefaultScalewayImage     = "ubuntu_jammy"
	DefaultScalewayType      = "DEV1-S"
)

// NodeDistribution defines how nodes are distributed across a provider.
// Used for true multi-cloud deployments where nodes span multiple providers.
type NodeDistribution struct {
	Provider      string // "docker", "ovh", "scaleway", "outscale"
	ControlPlanes int    // Number of control plane nodes on this provider
	Workers       int    // Number of worker nodes on this provider
}

// NodeInfo represents a provisioned node with its network information.
type NodeInfo struct {
	Name       string
	Role       string // "controlplane" or "worker"
	Provider   string
	InternalIP string
	PublicIP   string
	Index      int // Global index across all providers
}

// ClusterConfig holds the configuration for the Talos cluster.
type ClusterConfig struct {
	// General
	ClusterName       string
	KubernetesVersion string
	TalosVersion      string
	Endpoint          string // Internal LB endpoint for node-to-node
	PublicEndpoint    string // External endpoint for user access
	Domain            string

	// Node Distribution (Multi-Provider)
	// If empty, falls back to legacy single-provider mode
	Nodes []NodeDistribution

	// Legacy single-provider mode (deprecated, use Nodes instead)
	ControlPlaneNodes int
	WorkerNodes       int

	// Provider Specifics
	Docker   DockerConfig
	Scaleway ScalewayConfig
	Ovh      OvhConfig
	Outscale OutscaleConfig
	Denvr    DenvrConfig

	// Networking
	EnableWireGuard bool // Cilium WireGuard encryption for cross-cloud
}

type DockerConfig struct {
	NetworkName string
	Clouds      []string // Simulated cloud zones (e.g., "cloud-a", "cloud-b")
}

type ScalewayConfig struct {
	Region       string
	Zone         string
	ProjectID    string
	InstanceType string
	SnapshotID   string // Talos snapshot ID (from uploaded QCOW2)
}

type OvhConfig struct {
	Region      string
	FlavorName  string // Instance type
	ImageID     string // Talos image ID (from Glance)
	NetworkName string // Private network
	AuthURL     string // OpenStack auth URL
	TenantID    string
	TenantName  string
	UserName    string
	Password    string
	DomainName  string
}

type OutscaleConfig struct {
	Region       string
	InstanceType string
	ImageID      string // Talos AMI
	SubnetID     string
	KeypairName  string
}

type DenvrConfig struct {
	// Placeholder for Denvr (GPU cloud)
}

// LoadClusterConfigFromEnv reads configuration from environment variables.
func LoadClusterConfigFromEnv() *ClusterConfig {
	config := &ClusterConfig{
		ClusterName:       getEnv("CLUSTER_NAME", DefaultClusterName),
		KubernetesVersion: getEnv("KUBERNETES_VERSION", DefaultKubernetesVersion),
		TalosVersion:      getEnv("TALOS_VERSION", DefaultTalosVersion),
		Endpoint:          getEnv("CLUSTER_ENDPOINT", "openaether-local-lb"),
		PublicEndpoint:    getEnv("CLUSTER_PUBLIC_ENDPOINT", "127.0.0.1"),
		Domain:            getEnv("CLUSTER_DOMAIN", "cluster.local"),
		EnableWireGuard:   getEnvBool("ENABLE_WIREGUARD", true), // Default ON for cross-cloud

		// Legacy mode (used if NODE_DISTRIBUTION is not set)
		ControlPlaneNodes: getEnvInt("CONTROL_PLANE_NODES", 3),
		WorkerNodes:       getEnvInt("WORKER_NODES", 2),

		Docker: DockerConfig{
			NetworkName: getEnv("DOCKER_NETWORK_NAME", DefaultDockerNetwork),
			Clouds:      []string{"cloud-a", "cloud-b"}, // Default multi-cloud simulation
		},
		Scaleway: ScalewayConfig{
			Region:       getEnv("SCW_REGION", "fr-par"),
			Zone:         getEnv("SCW_ZONE", "fr-par-1"),
			ProjectID:    getEnv("SCW_PROJECT_ID", ""),
			InstanceType: getEnv("SCW_INSTANCE_TYPE", "DEV1-M"),
			SnapshotID:   getEnv("SCW_SNAPSHOT_ID", ""), // Talos snapshot
		},
		Ovh: OvhConfig{
			Region:      getEnv("OVH_REGION", "GRA11"),
			FlavorName:  getEnv("OVH_FLAVOR", "b2-7"),
			ImageID:     getEnv("OVH_IMAGE_ID", ""), // Talos image from Glance
			NetworkName: getEnv("OVH_NETWORK", "openaether-net"),
			AuthURL:     getEnv("OS_AUTH_URL", "https://auth.cloud.ovh.net/v3"),
			TenantID:    getEnv("OS_TENANT_ID", ""),
			TenantName:  getEnv("OS_TENANT_NAME", ""),
			UserName:    getEnv("OS_USERNAME", ""),
			Password:    getEnv("OS_PASSWORD", ""),
			DomainName:  getEnv("OS_USER_DOMAIN_NAME", "Default"),
		},
		Outscale: OutscaleConfig{
			Region:       getEnv("OSC_REGION", "eu-west-2"),
			InstanceType: getEnv("OSC_INSTANCE_TYPE", "tinav5.c2r4p1"), // 2 vCPU, 4GB RAM
			ImageID:      getEnv("OSC_IMAGE_ID", "ami-ce7e9d99"),       // Talos v1.12.0
			SubnetID:     getEnv("OSC_SUBNET_ID", ""),
			KeypairName:  getEnv("OSC_KEYPAIR", ""),
		},
	}

	// Parse NODE_DISTRIBUTION if set (multi-provider mode)
	// Format: "provider:cp:workers,provider:cp:workers,..."
	// Example: "ovh:1:2,scaleway:1:1,outscale:1:0"
	if distStr := os.Getenv("NODE_DISTRIBUTION"); distStr != "" {
		config.Nodes = parseNodeDistribution(distStr)
	}

	return config
}

// parseNodeDistribution parses the NODE_DISTRIBUTION env var.
// Format: "provider:cp_count:worker_count,..."
// Example: "docker:3:2" or "ovh:1:2,scaleway:1:1,outscale:1:0"
func parseNodeDistribution(distStr string) []NodeDistribution {
	var nodes []NodeDistribution

	parts := strings.Split(distStr, ",")
	for _, part := range parts {
		fields := strings.Split(strings.TrimSpace(part), ":")
		if len(fields) != 3 {
			continue // Skip malformed entries
		}

		provider := strings.TrimSpace(fields[0])
		cpCount, err := strconv.Atoi(strings.TrimSpace(fields[1]))
		if err != nil {
			cpCount = 0
		}
		workerCount, err := strconv.Atoi(strings.TrimSpace(fields[2]))
		if err != nil {
			workerCount = 0
		}

		if cpCount > 0 || workerCount > 0 {
			nodes = append(nodes, NodeDistribution{
				Provider:      provider,
				ControlPlanes: cpCount,
				Workers:       workerCount,
			})
		}
	}

	return nodes
}

// IsMultiProvider returns true if cluster uses multiple providers.
func (c *ClusterConfig) IsMultiProvider() bool {
	return len(c.Nodes) > 0
}

// TotalControlPlanes returns the total number of control plane nodes across all providers.
func (c *ClusterConfig) TotalControlPlanes() int {
	if !c.IsMultiProvider() {
		return c.ControlPlaneNodes
	}
	total := 0
	for _, n := range c.Nodes {
		total += n.ControlPlanes
	}
	return total
}

// TotalWorkers returns the total number of worker nodes across all providers.
func (c *ClusterConfig) TotalWorkers() int {
	if !c.IsMultiProvider() {
		return c.WorkerNodes
	}
	total := 0
	for _, n := range c.Nodes {
		total += n.Workers
	}
	return total
}

// GetProvidersUsed returns a list of unique provider names.
func (c *ClusterConfig) GetProvidersUsed() []string {
	if !c.IsMultiProvider() {
		return []string{getEnv("CLOUD_PROVIDER", "docker")}
	}
	providers := make([]string, 0, len(c.Nodes))
	for _, n := range c.Nodes {
		providers = append(providers, n.Provider)
	}
	return providers
}

// String returns a human-readable representation of the node distribution.
func (c *ClusterConfig) String() string {
	if !c.IsMultiProvider() {
		return fmt.Sprintf("single-provider: %d CP, %d Workers", c.ControlPlaneNodes, c.WorkerNodes)
	}

	var parts []string
	for _, n := range c.Nodes {
		parts = append(parts, fmt.Sprintf("%s:%dCP+%dW", n.Provider, n.ControlPlanes, n.Workers))
	}
	return fmt.Sprintf("multi-provider: [%s]", strings.Join(parts, ", "))
}

// Helper to get env param or default
func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

// Helper to get int env param or default
func getEnvInt(key string, fallback int) int {
	if value, ok := os.LookupEnv(key); ok {
		if i, err := strconv.Atoi(value); err == nil {
			return i
		}
	}
	return fallback
}

// Helper to check for boolean env var
func getEnvBool(key string, fallback bool) bool {
	if value, ok := os.LookupEnv(key); ok {
		return strings.ToLower(value) == "true" || value == "1"
	}
	return fallback
}
