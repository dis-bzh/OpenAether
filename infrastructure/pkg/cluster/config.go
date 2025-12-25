package cluster

import (
	"os"
	"strconv"
	"strings"
)

// Global constants for defaults
const (
	DefaultKubernetesVersion = "v1.35.0"
	DefaultTalosVersion      = "v1.12.0"
	DefaultClusterName       = "openaether"
	DefaultDockerNetwork     = "openaether-net"
	DefaultScalewayImage     = "ubuntu_jammy"
	DefaultScalewayType      = "DEV1-S"
)

// ClusterConfig holds the configuration for the Talos cluster.
type ClusterConfig struct {
	// General
	ClusterName       string
	KubernetesVersion string
	TalosVersion      string
	Endpoint          string
	PublicEndpoint    string
	Domain            string

	// Nodes
	ControlPlaneNodes int
	WorkerNodes       int

	// Provider Specifics
	Docker   DockerConfig
	Scaleway ScalewayConfig
	Ovh      OvhConfig
	Outscale OutscaleConfig
	Denvr    DenvrConfig
}

type DockerConfig struct {
	NetworkName string
	Clouds      []string
}

type ScalewayConfig struct {
	Image string
	Type  string
	// Add other Scaleway specific vars here (e.g. Zone, ProjectID) if not handled by env
}

type OvhConfig struct {
	// Placeholder for OVH
}

type OutscaleConfig struct {
	// Placeholder for Outscale
}

type DenvrConfig struct {
	// Placeholder for Denvr
}

// LoadClusterConfigFromEnv reads configuration from environment variables.
func LoadClusterConfigFromEnv() *ClusterConfig {
	return &ClusterConfig{
		ClusterName:       getEnv("CLUSTER_NAME", DefaultClusterName),
		KubernetesVersion: getEnv("KUBERNETES_VERSION", DefaultKubernetesVersion),
		TalosVersion:      getEnv("TALOS_VERSION", DefaultTalosVersion),
		// Endpoint: Internal Endpoint used by Nodes to talk to API Server (Load Balancer).
		// For Docker Local: Use the container name of the HAProxy LB.
		Endpoint: getEnv("CLUSTER_ENDPOINT", "openaether-local-lb"),
		// PublicEndpoint: External Endpoint used by User (kubeconfig).
		PublicEndpoint:    getEnv("CLUSTER_PUBLIC_ENDPOINT", "127.0.0.1"),
		Domain:            getEnv("CLUSTER_DOMAIN", "cluster.local"),
		ControlPlaneNodes: getEnvInt("CONTROL_PLANE_NODES", 3), // Default to 3 for HA simulation
		WorkerNodes:       getEnvInt("WORKER_NODES", 2),        // Default to 2 for multi-cloud simulation

		Docker: DockerConfig{
			// Default to simulating two clouds
			NetworkName: getEnv("DOCKER_NETWORK_NAME", DefaultDockerNetwork),
			Clouds:      []string{"cloud-a", "cloud-b"},
		},
		Scaleway: ScalewayConfig{
			Image: getEnv("SCW_IMAGE", DefaultScalewayImage),
			Type:  getEnv("SCW_INSTANCE_TYPE", DefaultScalewayType),
		},
	}
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
