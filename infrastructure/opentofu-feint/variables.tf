variable "target_provider" {
  description = "Which provider fixture to apply against the emulator."
  type        = string
  default     = "scaleway"

  validation {
    condition     = contains(["scaleway", "outscale"], var.target_provider)
    error_message = "target_provider must be scaleway or outscale — the emulator serves no other IaaS surface this root uses."
  }
}

variable "endpoint" {
  description = "Base URL of the running Feint emulator."
  type        = string
  default     = "http://127.0.0.1:4599"

  # Same rule as the cluster root's emulator_api_url: loopback or nothing. A
  # remote value here would create billable resources on somebody's account.
  validation {
    condition     = can(regex("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+$", var.endpoint))
    error_message = "endpoint must be a loopback URL (http://127.0.0.1:<port>): this root drives an emulator, never a real cloud."
  }
}

variable "cluster_name" {
  description = "Name prefix for the emulated resources."
  type        = string
  default     = "feint"
}

variable "private_cidr" {
  description = "Private range the bastion cloud-init locks its egress to."
  type        = string
  default     = "10.180.0.0/16"
}
