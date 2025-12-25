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
		Endpoint:          getEnv("CLUSTER_ENDPOINT", "127.0.0.1"), // Default for local
		Domain:            getEnv("CLUSTER_DOMAIN", "cluster.local"),
		ControlPlaneNodes: getEnvInt("CONTROL_PLANE_NODES", 1),
		WorkerNodes:       getEnvInt("WORKER_NODES", 1),

		Docker: DockerConfig{
			NetworkName: getEnv("DOCKER_NETWORK_NAME", DefaultDockerNetwork),
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
