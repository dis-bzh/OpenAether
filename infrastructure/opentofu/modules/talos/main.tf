resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Machine configuration data sources are removed from here.
# Each provider module will now generate its own machine configuration
# to allow for provider-specific customizations (like private IPs in certSANs).

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = ["localhost"]
  endpoints            = ["localhost"]
}
