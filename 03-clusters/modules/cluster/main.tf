terraform {
  required_providers {
    akp = {
      source  = "akuity/akp"
      version = "~> 0.10"
    }
  }
}

# ── Kubeconfig parsing ─────────────────────────────────────────────────────────
# The Akuity provider installs agents into the cluster itself, so it needs
# working credentials at plan/apply time.
#
# ASSUMPTION / GOTCHA: this module reads embedded client certificates
# (client-certificate-data / client-key-data) from the kubeconfig. That covers
# k3d, kind, minikube, k3s, and most on-prem distros. Managed-cloud kubeconfigs
# (EKS/GKE/AKS) usually use an exec plugin (aws/gke-gcloud-auth-plugin/kubelogin)
# instead — those have no cert data to extract. For such clusters, export a
# kubeconfig with static credentials (e.g. a service-account token) or extend
# this module to pass `token` in kube_config.

locals {
  kubeconfig = yamldecode(file(var.kubeconfig_path))

  # Resolve which context to use, in order of preference:
  #   1. explicit var.kubeconfig_context
  #   2. the file's current-context
  #   3. the first context in the file
  context_name = coalesce(
    var.kubeconfig_context,
    try(local.kubeconfig["current-context"], null),
    local.kubeconfig.contexts[0].name,
  )
  context = [for c in local.kubeconfig.contexts : c if c.name == local.context_name][0]
  cluster = [for c in local.kubeconfig.clusters : c if c.name == local.context.context.cluster][0]
  user    = [for u in local.kubeconfig.users : u if u.name == local.context.context.user][0]

  # GOTCHA: k3d (and other Docker-based clusters) bind the API server to
  # 0.0.0.0, which is not routable from the host running Terraform. Rewrite to
  # 127.0.0.1 so the provider can reach it. Harmless for real clusters, whose
  # server addresses never contain 0.0.0.0.
  host = replace(local.cluster.cluster.server, "0.0.0.0", "127.0.0.1")

  kube_config = {
    host                   = local.host
    cluster_ca_certificate = base64decode(local.cluster.cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.user.user["client-certificate-data"])
    client_key             = base64decode(local.user.user["client-key-data"])
  }
}

# ── Argo CD cluster registration ───────────────────────────────────────────────
# Registers the cluster with the Argo CD instance. The provider uses the
# supplied kubeconfig to install the Akuity agent into the "akuity" namespace;
# from then on the agent dials OUT to the control plane — no inbound access,
# no long-lived kubeconfig on the platform.

resource "akp_cluster" "this" {
  instance_id = var.argocd_instance_id
  name        = var.name
  namespace   = "akuity"

  # GOTCHA (two-phase fleet registration): keep this empty on first apply.
  # Labels like fleet=true typically feed ApplicationSet generators; if you
  # label the cluster before its agent is healthy, apps start syncing into a
  # half-installed agent. Apply once, verify the agent is healthy, then add
  # labels in a second apply. See docs/day-2.md.
  labels = var.labels

  spec = {
    # Explicit rather than defaulted: namespace_scoped forces REPLACEMENT when
    # it differs, and the platform stores `false` — leaving it unset makes
    # `terraform import` of an existing registration plan a destroy/recreate.
    # description/project: the platform normalizes unset strings to "", so
    # explicit "" keeps imported resources at zero diff.
    namespace_scoped = false
    description      = ""

    data = {
      size    = var.size
      project = ""

      # GOTCHA: on small/local clusters (k3d, kind, minikube) the default agent
      # CPU requests can exceed what's schedulable and leave pods Pending. The
      # kustomization patch shrinks argocd-application-controller and
      # argocd-repo-server requests, and runs a single repo-server replica, so
      # the agent fits.
      kustomization = var.tune_agent_resources ? file(var.kustomization_path) : null
    }
  }

  # Adopted clusters: no kube_config and no health gate, so the plan exactly
  # matches imported state and no update RPC is issued.
  kube_config = var.adopted ? null : local.kube_config

  # GOTCHA: ensure_healthy makes the apply BLOCK until the agent reports
  # healthy on the platform — so a successful apply means a live agent, and
  # stack ordering (03 after 01/02) is genuinely sequential. If the apply hangs
  # here, the agent pods are the first place to look:
  #   kubectl -n akuity get pods
  ensure_healthy = var.adopted ? false : true
}

# ── Kargo agent registration ───────────────────────────────────────────────────
# Self-hosted Kargo agent (akuity_managed = false): it runs inside this
# cluster and executes promotion steps locally. remote_argocd links Kargo
# promotions to Argo CD syncs — after Kargo writes a promotion to Git, it can
# observe/trigger the corresponding Argo CD Application on this instance.

resource "akp_kargo_agent" "this" {
  # manage_kargo_agent = false skips this resource — for adopting a cluster
  # whose Kargo agent already exists but cannot be imported (see the known
  # provider issue in docs/importing-existing.md: the agent read resolves the
  # wrong workspace and fails with PermissionDenied).
  count = var.manage_kargo_agent ? 1 : 0

  instance_id                 = var.kargo_instance_id
  workspace                   = "default"
  name                        = coalesce(var.kargo_agent_name, var.name)
  namespace                   = "akuity"
  reapply_manifests_on_update = true

  spec = {
    description = "Workload cluster: ${var.name}"
    data = {
      size           = var.size
      akuity_managed = false
      remote_argocd  = var.argocd_instance_id
    }
  }

  kube_config = local.kube_config

  # Install the Kargo agent only after the Argo CD agent is in and healthy —
  # both land in the same "akuity" namespace.
  depends_on = [akp_cluster.this]
}
