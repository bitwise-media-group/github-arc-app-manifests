# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Self-hosted GitHub Actions runners on AWS, installed onto a
# terraform-aws-eks-flux cluster as a self-contained application: the
# cluster root never learns github-arc exists. A root holding the cluster's
# application_target composes it:
#
#   module "github_arc" {
#     source  = ".../github-arc-app-manifests//modules/aws"
#     cluster = data.terraform_remote_state.cluster.outputs.application_target
#     github  = { config_url = "https://github.com/bitwise-media-group" }
#   }
#
# The same shape as modules/google but for the capacity: there is no node
# group here. The runners' dedicated scale-to-zero capacity is one Karpenter
# NodePool per elected arch, shipped in the image
# (aws/resourceset-nodes.yaml) on the platform's EC2NodeClass default
# and shaped by the GITHUB_ARC_<ARCH>_* vars this module publishes.
#
# Everything else that touches the cluster goes through terraform-aws-eks-
# flux's modules/application: the seed (application-github-arc), the
# github-arc-vars ConfigMap, the pre-created github-arc namespace and the
# podless IRSA reader role the sync KSA assumes
# (<cluster>-secrets-github-arc-github-arc-secrets, what
# ${SECRETS_ROLE_PREFIX}github-arc-github-arc-secrets resolves to in the
# manifests). The Secrets Manager secrets the image syncs are created here
# (or, with create_secrets = false, expected to exist); they carry no
# resource policy - the read grant is the reader role's, scoped to
# ${cluster.secret_prefix}*.
#
# The credential VALUES are put out of band (aws secretsmanager
# put-secret-value - never terraform state), so destroying this module (with
# create_secrets) destroys them with the secrets.

locals {
  architectures = ["amd64", "arm64"]

  instance_families = {
    amd64 = ["m7i", "m7a"]
    arm64 = ["m7g", "m8g"]
  }

  # Every architecture, elected or not, so the vars below always carry both
  # (the manifests read every GITHUB_ARC_<ARCH>_* key bare); an absent key
  # is an unelected arch at the input defaults.
  runners = {
    for arch in local.architectures : arch => (
      contains(keys(var.runners), arch)
      ? merge(var.runners[arch], {
        instance_families = var.runners[arch].instance_families != null ? sort(tolist(var.runners[arch].instance_families)) : local.instance_families[arch]
        capacity_types    = sort(tolist(var.runners[arch].capacity_types))
      })
      : {
        enabled           = false
        instance_families = local.instance_families[arch]
        capacity_types    = ["on-demand"]
        max_nodes         = 4
        max_runners       = 4
        cpu               = "3"
        memory            = "10Gi"
        cpu_limit         = "16"
        memory_limit      = "64Gi"
        consolidate_after = "5m"
      }
    )
  }

  # The application's own ConfigMap (github-arc-vars), substituted into the
  # manifests alongside cluster-vars. Same conventions as the platform
  # contract: comma-joined sorted lists (an empty string for an empty
  # instance-family set, which drops the requirement), "true"/"false"
  # literals for booleans, the empty string for an unset runner group.
  vars = merge(
    {
      GITHUB_ARC_CONFIG_URL   = var.github.config_url
      GITHUB_ARC_RUNNER_GROUP = var.github.runner_group != null ? var.github.runner_group : ""

    },
    merge([
      for arch, runner in local.runners : {
        "GITHUB_ARC_${upper(arch)}_ENABLED"           = runner.enabled ? "true" : "false"
        "GITHUB_ARC_${upper(arch)}_MAX_RUNNERS"       = tostring(runner.max_runners)
        "GITHUB_ARC_${upper(arch)}_CPU"               = runner.cpu
        "GITHUB_ARC_${upper(arch)}_MEMORY"            = runner.memory
        "GITHUB_ARC_${upper(arch)}_INSTANCE_FAMILIES" = join(",", runner.instance_families)
        "GITHUB_ARC_${upper(arch)}_CAPACITY_TYPES"    = join(",", runner.capacity_types)
        "GITHUB_ARC_${upper(arch)}_MAX_NODES"         = tostring(runner.max_nodes)
        "GITHUB_ARC_${upper(arch)}_CPU_LIMIT"         = runner.cpu_limit
        "GITHUB_ARC_${upper(arch)}_MEMORY_LIMIT"      = runner.memory_limit
        "GITHUB_ARC_${upper(arch)}_CONSOLIDATE_AFTER" = runner.consolidate_after
      }
    ]...),
  )

  # secret name -> description: the GitHub App credential, one secret per
  # Secret key ARC reads. The image's SecretProviderClass names exactly
  # these under SECRET_PREFIX.
  containers = {
    github-arc-app-id          = "The github-arc GitHub App's numeric App ID"
    github-arc-installation-id = "The github-arc GitHub App's numeric installation ID on the runners' org"
    github-arc-private-key     = "The github-arc GitHub App's private key (PEM)"
  }
}

resource "aws_secretsmanager_secret" "main" {
  for_each = var.create_secrets ? local.containers : {}

  name        = "${var.cluster.secret_prefix}${each.key}"
  description = "${each.value}. Values arrive out of band; readable by github-arc's secret-sync reader role on ${var.cluster.name}."

  tags = var.tags
}

# The cluster-facing half, through the cluster module's own standalone
# application module: every name it mints (release application-github-arc,
# ConfigMap github-arc-vars, role <cluster>-secrets-github-arc-github-arc-secrets)
# is the one the manifests expect.
module "application" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application?ref=9fa078f941c9ba8ef97d38eb1fd9ebea01a80999"

  name    = "github-arc"
  cluster = var.cluster

  image = {
    url     = "oci://${var.cluster.platform_registry}/manifests/github-arc"
    semver  = var.image.semver
    channel = var.image.channel
    # the image's per-cloud tree sits at its root (./aws, ./google)
    path = "./${var.cluster.tree}"
    # the first install also waits on the GitHub App secret sync (the
    # image's own Kustomization carries the same 10m)
    timeout = "10m"
    # mirrors the image's own Kustomization: secret-sync for the SecretSync
    # CRD and controller, karpenter for the NodePool CRD
    depends_on = ["kyverno-policies", "arc", "secret-sync", "karpenter"]
    # keyless clusters pin this repo's publish identity; KMS-keyed clusters
    # verify against the cosign-pub Secret instead
    verify = {
      subject = var.cluster.keyed ? null : var.signed_identity_subject
      keyed   = var.cluster.keyed
    }
  }

  vars       = merge(var.extra_vars, local.vars)
  namespaces = ["github-arc"]

  # The podless sync KSA (aws/service-accounts.yaml annotates it with
  # ${SECRETS_ROLE_PREFIX}github-arc-github-arc-secrets).
  secret_readers = [
    { namespace = "github-arc", service_account = "github-arc-secrets" },
  ]

  tags = var.tags
}
