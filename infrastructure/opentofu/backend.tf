variable "encryption_passphrase" {
  type      = string
  sensitive = true

  validation {
    condition     = length(var.encryption_passphrase) >= 32
    error_message = "encryption_passphrase must be at least 32 characters long for SSE-C key derivation."
  }
}

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

  # Partial backend: bucket / key / region / endpoint are DERIVED from the
  # cluster's tfvars (the single source of truth) so each cluster gets its OWN
  # encrypted state, following s3-<project>-<provider>-tfstate-<env> (key
  # <cluster_name>.tfstate). Initialise with:
  #   tofu init -reconfigure $(scripts/tf-backend.sh envs/<cluster>.tfvars)
  # The Taskfile does this for you. The state payload is client-encrypted by the
  # encryption{} block above before it ever reaches S3.
  backend "s3" {
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
