output "machine_secrets" {
  value     = talos_machine_secrets.this.machine_secrets
  sensitive = true
}

output "client_configuration" {
  value     = talos_machine_secrets.this.client_configuration
  sensitive = true
}

# Machine configurations are now handled in provider modules.

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  # Kubeconfig is usually retrieved after bootstrap, requiring access to the cluster. 
  # For now we enable generating it if we have the CA.
  # But usually talos_cluster_kubeconfig data source is used.
  value = ""
}
