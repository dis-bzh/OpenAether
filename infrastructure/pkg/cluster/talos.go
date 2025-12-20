package cluster

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"math/big"
	"time"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	"github.com/pulumi/pulumi-docker/sdk/v4/go/docker"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumiverse/pulumi-scaleway/sdk/go/scaleway"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
	"gopkg.in/yaml.v3"
)

type TalosClusterArgs struct {
	ControlPlaneNodes int
	WorkerNodes       int
	CloudProvider     string // "docker", "scaleway", "ovh", "outscale", "denvr"
	ClusterName       string
	Endpoint          string // API Endpoint (VIP or LoadBalancer IP)
}

type TalosCluster struct {
	pulumi.ResourceState
	Kubeconfig  pulumi.StringOutput
	Talosconfig pulumi.StringOutput
}

// NewTalosCluster creates a new abstract Talos Cluster.
func NewTalosCluster(ctx *pulumi.Context, name string, args *TalosClusterArgs, opts ...pulumi.ResourceOption) (*TalosCluster, error) {
	cluster := &TalosCluster{}
	err := ctx.RegisterComponentResource("openaether:cluster:TalosCluster", name, cluster, opts...)
	if err != nil {
		return nil, err
	}

	// 1. Generate Machine Secrets
	secrets, err := machine.NewSecrets(ctx, name+"-secrets", &machine.SecretsArgs{
		TalosVersion: pulumi.String("v1.11.6"),
	}, pulumi.Parent(cluster))
	if err != nil {
		return nil, err
	}

	// 2. Generate Machine Configuration (Control Plane)
	cpConfig := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
		ClusterName:       pulumi.String(args.ClusterName),
		MachineType:       pulumi.String("controlplane"),
		ClusterEndpoint:   pulumi.Sprintf("https://%s:6443", args.Endpoint),
		MachineSecrets:    secrets.MachineSecrets,
		TalosVersion:      pulumi.String("v1.11.6"),
		KubernetesVersion: pulumi.String("v1.32.0"),
		Docs:              pulumi.Bool(false),
		Examples:          pulumi.Bool(false),
	}, pulumi.Parent(cluster))

	if err != nil {
		return nil, err
	}

	var cpIp pulumi.StringOutput
	var firstConfigApply *machine.ConfigurationApply

	// 3. Provision Infrastructure (Docker/Scaleway)
	if args.CloudProvider == "scaleway" {
		// Provision Control Plane Nodes on Scaleway
		for i := 0; i < args.ControlPlaneNodes; i++ {
			nodeName := fmt.Sprintf("%s-cp-%d", name, i)
			server, err := scaleway.NewInstanceServer(ctx, nodeName, &scaleway.InstanceServerArgs{
				Type:  pulumi.String("DEV1-S"),
				Image: pulumi.String("ubuntu_jammy"), // Ideally Talos Image
				Tags:  pulumi.StringArray{pulumi.String("role=control-plane")},
			}, pulumi.Parent(cluster))
			if err != nil {
				return nil, err
			}
			if i == 0 {
				cpIp = server.PublicIps.Index(pulumi.Int(0)).Address().Elem()
			}
		}
	} else if args.CloudProvider == "docker" {
		// Ensure the network exists
		networkName := "openaether-net"
		_, err := docker.NewNetwork(ctx, networkName, &docker.NetworkArgs{
			Name:           pulumi.String(networkName),
			Driver:         pulumi.String("bridge"),
			CheckDuplicate: pulumi.Bool(true),
		})
		if err != nil {
			return nil, err
		}

		// Provision Control Plane Nodes on Docker
		for i := 0; i < args.ControlPlaneNodes; i++ {
			nodeName := fmt.Sprintf("%s-cp-%d", name, i)

			// We need to run as privileged for Talos to work in Docker
			container, err := docker.NewContainer(ctx, nodeName, &docker.ContainerArgs{
				Image: pulumi.String("ghcr.io/siderolabs/talos:v1.11.6"),
				Name:  pulumi.String(nodeName),
				Volumes: docker.ContainerVolumeArray{
					&docker.ContainerVolumeArgs{
						HostPath:      pulumi.String("/dev"),
						ContainerPath: pulumi.String("/dev"),
					},
					&docker.ContainerVolumeArgs{
						HostPath:      pulumi.String("/run/udev"),
						ContainerPath: pulumi.String("/run/udev"),
						ReadOnly:      pulumi.Bool(true),
					},
					// Official Talos Docker Volumes (Anonymous)
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/system/state"),
					},
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/var"),
					},
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/etc/cni"),
					},
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/etc/kubernetes"),
					},
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/usr/libexec/kubernetes"),
					},
					&docker.ContainerVolumeArgs{
						ContainerPath: pulumi.String("/opt"),
					},
				},
				Tmpfs: pulumi.StringMap{
					"/run":    pulumi.String("rw"),
					"/system": pulumi.String("rw"),
					"/tmp":    pulumi.String("rw"),
				},
				CgroupnsMode: pulumi.String("private"),
				ReadOnly:     pulumi.Bool(true), // Talos expects read-only rootfs
				Privileged:   pulumi.Bool(true),
				Envs: pulumi.StringArray{
					pulumi.String("PLATFORM=container"),
				},
				NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
					&docker.ContainerNetworksAdvancedArgs{
						Name: pulumi.String("openaether-net"),
					},
				},

				Ports: docker.ContainerPortArray{
					&docker.ContainerPortArgs{
						Internal: pulumi.Int(6443),
						External: pulumi.Int(6443),
					},
					&docker.ContainerPortArgs{
						Internal: pulumi.Int(50000),
						External: pulumi.Int(50000),
					},
				},
			}, pulumi.Parent(cluster))
			if err != nil {
				return nil, err
			}

			// Transform the config to remove "install" section explicitly and add certSANs
			// This is more robust than ConfigPatches for removing sections
			containerConfig := cpConfig.MachineConfiguration().ApplyT(func(config string) (string, error) {
				var data map[string]interface{}
				if err := yaml.Unmarshal([]byte(config), &data); err != nil {
					return "", err
				}

				// Helper to append unique string to slice interface
				appendUnique := func(slice []interface{}, item string) []interface{} {
					for _, s := range slice {
						if s == item {
							return slice
						}
					}
					return append(slice, item)
				}

				if machine, ok := data["machine"].(map[string]interface{}); ok {
					delete(machine, "install")

					// Inject certSANs for machine
					var certSANs []interface{}
					if existing, ok := machine["certSANs"].([]interface{}); ok {
						certSANs = existing
					}
					machine["certSANs"] = appendUnique(certSANs, "127.0.0.1")
				}

				if cluster, ok := data["cluster"].(map[string]interface{}); ok {
					if apiServer, ok := cluster["apiServer"].(map[string]interface{}); ok {
						// Inject certSANs for apiServer
						var certSANs []interface{}
						if existing, ok := apiServer["certSANs"].([]interface{}); ok {
							certSANs = existing
						}
						apiServer["certSANs"] = appendUnique(certSANs, "127.0.0.1")
					}
				}

				out, err := yaml.Marshal(data)
				if err != nil {
					return "", err
				}
				return string(out), nil
			}).(pulumi.StringOutput)

			// Apply Configuration to the Node
			// Note: For Docker local, we verify config against localhost (mapped port)
			// But the node address inside the config apply should be the container IP if inside the net, or localhost if outside.
			// Pulumi Talos provider runs on Host.
			configApply, err := machine.NewConfigurationApply(ctx, fmt.Sprintf("%s-apply", nodeName), &machine.ConfigurationApplyArgs{
				ClientConfiguration:       secrets.ClientConfiguration,
				MachineConfigurationInput: containerConfig,
				Node:                      pulumi.String("127.0.0.1"), // Targeting localhost for Setup
				Endpoint:                  pulumi.String("127.0.0.1"),
			}, pulumi.Parent(container), pulumi.DependsOn([]pulumi.Resource{container}))
			if err != nil {
				return nil, err
			}

			if i == 0 {
				firstConfigApply = configApply
			}

			if i == 0 {
				cpIp = pulumi.String("127.0.0.1").ToStringOutput()
			}
		}
	} else if args.CloudProvider == "ovh" {
		ctx.Log.Warn("OVH provider not yet implemented", nil)
	}

	// 4. Bootstrap Cluster
	// Only needed for the first node
	// 4. Wait for Talos to be ready (TCP 50000)
	// The user suspects Unimplemented error is due to timing/readiness.
	// We wait for the port to be open and give it a small grace period for services to register.
	waitForTalos, err := local.NewCommand(ctx, name+"-wait-for-talos", &local.CommandArgs{
		Create: pulumi.Sprintf(`echo "Waiting for Talos API at %s:50000..."
timeout 60s bash -c 'until echo > /dev/tcp/127.0.0.1/50000; do sleep 1; done'
echo "Talos API port is open. Waiting 10s for services to settle..."
sleep 10
`, cpIp),
	}, pulumi.Parent(cluster), pulumi.DependsOn([]pulumi.Resource{firstConfigApply}))
	if err != nil {
		return nil, err
	}

	// 5. Bootstrap Cluster
	// Only needed for the first node
	if firstConfigApply != nil {
		_, err = machine.NewBootstrap(ctx, name+"-bootstrap", &machine.BootstrapArgs{
			ClientConfiguration: secrets.ClientConfiguration,
			Node:                cpIp,
			Endpoint:            cpIp,
		}, pulumi.Parent(cluster), pulumi.DependsOn([]pulumi.Resource{waitForTalos}))
		if err != nil {
			return nil, err
		}
	}

	ctx.Export("clusterInfo", pulumi.Sprintf("Provisioning Cluster %s on %s with %d CPs", name, args.CloudProvider, args.ControlPlaneNodes))

	// Manually construct GLOBAL Kubeconfig with proper Admin Certs
	// We must sign a new client certificate because the provider doesn't export the admin kubeconfig directly.
	cluster.Kubeconfig = pulumi.All(
		secrets.MachineSecrets.Certs().K8s().Cert(),
		secrets.MachineSecrets.Certs().K8s().Key(),
		args.Endpoint,
	).ApplyT(func(args []interface{}) (string, error) {
		// Helper to safely get string from interface{} that might be string or *string
		getString := func(v interface{}, name string) (string, error) {
			switch val := v.(type) {
			case string:
				return val, nil
			case *string:
				if val == nil {
					return "", fmt.Errorf("%s is nil", name)
				}
				return *val, nil
			default:
				return "", fmt.Errorf("unexpected type for %s: %T", name, v)
			}
		}

		caPem, err := getString(args[0], "CA Cert")
		if err != nil {
			return "", err
		}
		caKeyPem, err := getString(args[1], "CA Key")
		if err != nil {
			return "", err
		}
		endpoint := args[2].(string)

		// 1. Parse CA Cert and Key
		// Helper to robustly decode PEM (handles optional Base64 encoding)
		decodePEM := func(raw string) (*pem.Block, error) {
			// Try direct PEM decode
			block, _ := pem.Decode([]byte(raw))
			if block != nil {
				return block, nil
			}

			// Try Base64 decode first
			decoded, err := base64.StdEncoding.DecodeString(raw)
			if err == nil {
				block, _ = pem.Decode(decoded)
				if block != nil {
					return block, nil
				}
			}

			// Return error with snippet for debugging
			snippet := raw
			if len(snippet) > 50 {
				snippet = snippet[:50] + "..."
			}
			return nil, fmt.Errorf("failed to parse PEM (starts with: %q)", snippet)
		}

		caCertBlock, err := decodePEM(caPem)
		if err != nil {
			return "", fmt.Errorf("CA Cert: %w", err)
		}
		caCert, err := x509.ParseCertificate(caCertBlock.Bytes)
		if err != nil {
			return "", err
		}

		caKeyBlock, err := decodePEM(caKeyPem)
		if err != nil {
			return "", fmt.Errorf("CA Key: %w", err)
		}
		// Try parsing as PKCS1, then PKCS8, then EC
		var caKey interface{}
		if k, err := x509.ParsePKCS1PrivateKey(caKeyBlock.Bytes); err == nil {
			caKey = k
		} else if k, err := x509.ParsePKCS8PrivateKey(caKeyBlock.Bytes); err == nil {
			caKey = k
		} else if k, err := x509.ParseECPrivateKey(caKeyBlock.Bytes); err == nil {
			caKey = k
		} else {
			return "", fmt.Errorf("failed to parse CA Private Key")
		}

		// 2. Generate Admin Key
		adminKey, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return "", err
		}

		// 3. Create Certificate Request (Template)
		adminCertTmpl := x509.Certificate{
			SerialNumber: big.NewInt(time.Now().UnixNano()),
			Subject: pkix.Name{
				CommonName:   "kubernetes-admin",
				Organization: []string{"system:masters"},
			},
			NotBefore:             time.Now(),
			NotAfter:              time.Now().Add(365 * 24 * time.Hour), // 1 Year
			KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
		}

		// 4. Sign Certificate
		adminCertBytes, err := x509.CreateCertificate(rand.Reader, &adminCertTmpl, caCert, &adminKey.PublicKey, caKey)
		if err != nil {
			return "", err
		}

		// 5. Encode to PEM
		adminCertPem := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: adminCertBytes})
		adminKeyPem := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(adminKey)})

		// 6. Base64 Encode for Kubeconfig (Data fields)
		// Use the parsed caCertBlock to generate a clean PEM string, preventing double-encoding issue
		caData := base64.StdEncoding.EncodeToString(pem.EncodeToMemory(caCertBlock))
		certData := base64.StdEncoding.EncodeToString(adminCertPem)
		keyData := base64.StdEncoding.EncodeToString(adminKeyPem)

		return fmt.Sprintf(`apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: %s
    server: https://%s:6443
  name: %s
contexts:
- context:
    cluster: %s
    user: admin
  name: admin@%s
current-context: admin@%s
kind: Config
preferences: {}
users:
- name: admin
  user:
    client-certificate-data: %s
    client-key-data: %s
`, caData, endpoint, name, name, name, name, certData, keyData), nil
	}).(pulumi.StringOutput)

	// Manually construct Talosconfig
	cluster.Talosconfig = pulumi.All(
		secrets.ClientConfiguration.CaCertificate(),
		secrets.ClientConfiguration.ClientCertificate(),
		secrets.ClientConfiguration.ClientKey(),
		args.Endpoint,
	).ApplyT(func(args []interface{}) string {
		ca := args[0].(string)
		crt := args[1].(string)
		key := args[2].(string)
		endpoint := args[3].(string)

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
`, name, name, endpoint, endpoint, ca, crt, key)
	}).(pulumi.StringOutput)

	return cluster, nil
}
