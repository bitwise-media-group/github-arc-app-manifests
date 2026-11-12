# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The seed release (application-github-arc) in the cluster's flux namespace, reconciled by every apply."
  value       = module.application.release
}

output "vars" {
  description = <<-EOT
    The github-arc-vars ConfigMap contents: every application-owned key the manifests substitute - the GitHub config
    URL and runner group, the per-arch GITHUB_ARC_<ARCH>_{ENABLED,MAX_RUNNERS,CPU,MEMORY}, the manifests semver range
    and signing subject - plus extra_vars.
  EOT
  value       = merge(var.extra_vars, local.vars)
}

output "node_pools" {
  description = <<-EOT
    The dedicated runner node pools, keyed by elected architecture: the pool name (the
    cloud.google.com/gke-nodepool value the runner pods select), its id and its Kubernetes labels.
  EOT
  value = {
    for arch, pool in module.node_pool : arch => {
      name   = pool.name
      id     = pool.id
      labels = pool.labels
    }
  }
}

output "secrets" {
  description = <<-EOT
    The GitHub App credential containers, keyed by unprefixed name: the resource id, the (prefixed) secret id and
    whether this module created it (create_secrets). Versions are added out of band: gcloud secrets versions add <id>
    --data-file=-.
  EOT
  value = {
    for name in local.containers : name => {
      id        = var.create_secrets ? google_secret_manager_secret.main[name].id : "projects/${var.cluster.project}/secrets/${var.cluster.secret_prefix}${name}"
      secret_id = "${var.cluster.secret_prefix}${name}"
      created   = var.create_secrets
    }
  }
}
