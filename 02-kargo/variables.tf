variable "org_name" {
  description = "Akuity Platform organization name"
  type        = string
}

variable "argocd_instance_name" {
  description = "Name of the Argo CD instance created by stack 01-argocd (looked up by name — no remote state needed)"
  type        = string
  default     = "quickstart-argocd"
}

variable "kargo_instance_name" {
  description = "Name for the Kargo instance on the Akuity Platform"
  type        = string
  default     = "quickstart-kargo"
}

variable "kargo_version" {
  description = "Kargo version to deploy (Akuity build, e.g. v1.11.2-ak.0)"
  type        = string
  default     = "v1.11.2-ak.0"
}

variable "admin_password" {
  description = <<-EOT
    Admin password for the Kargo instance.
    Set via environment variable to keep it out of files:
      export TF_VAR_admin_password="..."
  EOT
  type        = string
  sensitive   = true
}

variable "promo_controller_enabled" {
  description = "Run the promotion controller on the Akuity-hosted control plane. Set false when self-hosted agents (03-clusters) run promotions instead."
  type        = bool
  default     = true
}
