# ==============================================================================
# Separate, encrypted state from the cluster root: the image is built once per
# Talos version and reused by every cluster apply (decoupled lifecycle).
# ==============================================================================

terraform {
  encryption {
    key_provider "pbkdf2" "migration_key" {
      passphrase = var.encryption_passphrase
    }

    method "aes_gcm" "migration_method" {
      keys = key_provider.pbkdf2.migration_key
    }

    state {
      method = method.aes_gcm.migration_method
    }

    plan {
      method = method.aes_gcm.migration_method
    }
  }

  backend "s3" {
    bucket                      = "s3-openaether-tfstate"
    key                         = "talos-image.tfstate"
    region                      = "fr-par"
    endpoint                    = "https://s3.fr-par.scw.cloud"
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
