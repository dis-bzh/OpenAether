# ==============================================================================
# Local Provider — Docker-based Talos cluster for local testing
#
# Runs N control plane (+ optional worker) containers on a dedicated Docker
# network with static IPs, mirroring `talosctl cluster create docker` and the
# Talos Docker platform docs:
#   - --read-only, --privileged, seccomp=unconfined, PLATFORM=container
#   - tmpfs: /run /system /tmp ; volumes: /system/state /var /etc/cni
#     /etc/kubernetes /usr/libexec/kubernetes /opt
#   - machine config injected via USERDATA env var (maintenance-mode apply
#     reboot-loops in containers — see the Docker platform caveats)
#
# WSL2 + Docker Desktop: container IPs (10.5.0.x) are NOT routable from the
# host, so the Talos/K8s APIs are reached via 127.0.0.1 port mappings:
#   cp_i Talos API  → 127.0.0.1:(talos_api_port_base + i)
#   cp_0 K8s API     → 127.0.0.1:k8s_api_port
# Inter-node traffic (etcd, kube) uses the 10.5.0.x Docker network directly.
# ==============================================================================

locals {
  net_prefix = join(".", slice(split(".", cidrhost(var.network_cidr, 0)), 0, 3))

  cp_names = [for i in range(var.control_plane_count) : "${var.cluster_name}-cp-${i}"]
  cp_ips   = [for i in range(var.control_plane_count) : "${local.net_prefix}.${var.cp_ip_base + i}"]
  cp_ports = [for i in range(var.control_plane_count) : var.talos_api_port_base + i]

  worker_names = [for i in range(var.worker_count) : "${var.cluster_name}-worker-${i}"]
  worker_ips   = [for i in range(var.worker_count) : "${local.net_prefix}.${var.worker_ip_base + i}"]
  worker_ports = [for i in range(var.worker_count) : var.talos_api_port_base + 100 + i]

  talos_image = "ghcr.io/siderolabs/talos:${var.talos_version}"

  # Shared docker run flags (Talos Docker platform requirements)
  common_run_flags = join(" ", [
    "--read-only",
    "--privileged",
    "--security-opt seccomp=unconfined",
    "-e PLATFORM=container",
    "--mount type=tmpfs,destination=/run",
    "--mount type=tmpfs,destination=/system",
    "--mount type=tmpfs,destination=/tmp",
  ])
}

# ==============================================================================
# Docker Network (dedicated subnet so we can assign static IPs)
# ==============================================================================

resource "terraform_data" "network" {
  triggers_replace = ["${var.cluster_name}-net", var.network_cidr]

  provisioner "local-exec" {
    command = "docker network create '${var.cluster_name}-net' --subnet '${var.network_cidr}' 2>/dev/null || true"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "docker network rm ${self.triggers_replace[0]} 2>/dev/null || true"
  }
}

# ==============================================================================
# Control Plane Containers
# ==============================================================================

resource "terraform_data" "control_plane" {
  count = var.control_plane_count

  triggers_replace = [
    local.cp_names[count.index],
    local.talos_image,
    local.cp_ips[count.index],
    tostring(local.cp_ports[count.index]),
    # Recreate when this node's config changes
    length(var.control_plane_configs) > count.index ? sha256(var.control_plane_configs[count.index]) : "no-config",
  ]

  # USERDATA injected via the provisioner environment, passed through to the
  # container with `--env USERDATA` (avoids ARG_MAX / --env-file line limits).
  provisioner "local-exec" {
    environment = {
      USERDATA = length(var.control_plane_configs) > count.index ? base64encode(var.control_plane_configs[count.index]) : ""
    }
    command = <<-EOF
      set -e
      NAME="${local.cp_names[count.index]}"
      docker rm -f "$NAME" 2>/dev/null || true
      docker pull "${local.talos_image}" >/dev/null 2>&1 || true

      # cp_0 also publishes the Kubernetes API port
      K8S_PORT_FLAG=""
      if [ "${count.index}" = "0" ]; then
        K8S_PORT_FLAG="--publish 127.0.0.1:${var.k8s_api_port}:6443"
      fi

      USERDATA_FLAG=""
      if [ -n "$USERDATA" ]; then USERDATA_FLAG="--env USERDATA"; fi

      docker run --detach \
        --name "$NAME" \
        --hostname "$NAME" \
        ${local.common_run_flags} \
        --mount type=volume,source=$NAME-state,destination=/system/state \
        --mount type=volume,source=$NAME-var,destination=/var \
        --mount type=volume,source=$NAME-etccni,destination=/etc/cni \
        --mount type=volume,source=$NAME-etck8s,destination=/etc/kubernetes \
        --mount type=volume,source=$NAME-libexec,destination=/usr/libexec/kubernetes \
        --mount type=volume,source=$NAME-opt,destination=/opt \
        --network "${var.cluster_name}-net" \
        --ip "${local.cp_ips[count.index]}" \
        --publish "127.0.0.1:${local.cp_ports[count.index]}:50000" \
        $K8S_PORT_FLAG \
        --restart unless-stopped \
        $USERDATA_FLAG \
        "${local.talos_image}"

      echo "Waiting for Talos API on 127.0.0.1:${local.cp_ports[count.index]}..."
      for i in $(seq 1 45); do
        if nc -z 127.0.0.1 ${local.cp_ports[count.index]} 2>/dev/null; then
          echo "$NAME Talos API ready"
          exit 0
        fi
        sleep 2
      done
      echo "ERROR: $NAME Talos API not ready after 90s"
      docker logs "$NAME" 2>&1 | tail -20
      exit 1
    EOF
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      docker rm -f ${self.triggers_replace[0]} 2>/dev/null || true
      for v in state var etccni etck8s libexec opt; do
        docker volume rm "${self.triggers_replace[0]}-$v" 2>/dev/null || true
      done
    EOF
  }

  depends_on = [terraform_data.network]
}

# ==============================================================================
# Worker Containers
# ==============================================================================

resource "terraform_data" "worker" {
  count = var.worker_count

  triggers_replace = [
    local.worker_names[count.index],
    local.talos_image,
    local.worker_ips[count.index],
    tostring(local.worker_ports[count.index]),
    length(var.worker_configs) > count.index ? sha256(var.worker_configs[count.index]) : "no-config",
  ]

  provisioner "local-exec" {
    environment = {
      USERDATA = length(var.worker_configs) > count.index ? base64encode(var.worker_configs[count.index]) : ""
    }
    command = <<-EOF
      set -e
      NAME="${local.worker_names[count.index]}"
      docker rm -f "$NAME" 2>/dev/null || true
      docker pull "${local.talos_image}" >/dev/null 2>&1 || true

      USERDATA_FLAG=""
      if [ -n "$USERDATA" ]; then USERDATA_FLAG="--env USERDATA"; fi

      docker run --detach \
        --name "$NAME" \
        --hostname "$NAME" \
        ${local.common_run_flags} \
        --mount type=volume,source=$NAME-state,destination=/system/state \
        --mount type=volume,source=$NAME-var,destination=/var \
        --mount type=volume,source=$NAME-etccni,destination=/etc/cni \
        --mount type=volume,source=$NAME-etck8s,destination=/etc/kubernetes \
        --mount type=volume,source=$NAME-libexec,destination=/usr/libexec/kubernetes \
        --mount type=volume,source=$NAME-opt,destination=/opt \
        --network "${var.cluster_name}-net" \
        --ip "${local.worker_ips[count.index]}" \
        --publish "127.0.0.1:${local.worker_ports[count.index]}:50000" \
        --restart unless-stopped \
        $USERDATA_FLAG \
        "${local.talos_image}"

      for i in $(seq 1 45); do
        nc -z 127.0.0.1 ${local.worker_ports[count.index]} 2>/dev/null && { echo "$NAME ready"; exit 0; }
        sleep 2
      done
      echo "ERROR: $NAME Talos API not ready"; exit 1
    EOF
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      docker rm -f ${self.triggers_replace[0]} 2>/dev/null || true
      for v in state var etccni etck8s libexec opt; do
        docker volume rm "${self.triggers_replace[0]}-$v" 2>/dev/null || true
      done
    EOF
  }

  depends_on = [terraform_data.network]
}
