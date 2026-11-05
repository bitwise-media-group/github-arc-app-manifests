# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The bootstrap-only seed release (application-github-arc) in the cluster's flux namespace."
  value       = module.application.release
}

output "vars" {
  description = <<-EOT
    The github-arc-vars ConfigMap contents: every application-owned key the manifests substitute - the GitHub config
    URL and runner group, the per-arch GITHUB_ARC_<ARCH>_* scale-set and Karpenter NodePool settings, the manifests
    semver range and signing subject - plus extra_vars.
  EOT
  value       = merge(var.extra_vars, local.vars)
}

output "node_pools" {
  description = <<-EOT
    The Karpenter NodePools the image renders, keyed by elected architecture: the NodePool name and the
    platform.bitwisemedia.uk/node-pool label its nodes carry (and the runner pods select). The NodePools themselves are
    flux's, not terraform's.
  EOT
  value = {
    for arch, runner in local.runners : arch => {
      name   = "github-arc-${arch}"
      labels = { "platform.bitwisemedia.uk/node-pool" = "github-arc-${arch}" }
    } if runner.enabled
  }
}

output "secret_reader_roles" {
  description = "The podless secret-sync reader role ARN, keyed <namespace>/<service_account>: github-arc/github-arc-secrets."
  value       = module.application.secret_reader_roles
}

output "secrets" {
  description = <<-EOT
    The GitHub App credential secrets, keyed by unprefixed name: the (prefixed) Secrets Manager name, its ARN (null when
    create_secrets is false - the secret is another root's) and whether this module created it. Every value is put out
    of band: aws secretsmanager put-secret-value --secret-id <name>.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      name    = "${var.cluster.secret_prefix}${name}"
      arn     = var.create_secrets ? aws_secretsmanager_secret.main[name].arn : null
      created = var.create_secrets
    }
  }
}
