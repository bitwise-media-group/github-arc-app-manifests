# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster" {
  description = <<-EOT
    The cluster to install github-arc onto: pass terraform-aws-eks-flux's application_target output verbatim (through
    terraform_remote_state or any other channel). It is handed to that repo's modules/application unchanged, and
    supplies the cluster name (IAM role names), the platform registry the image is published beneath
    (oci://<platform_registry>/manifests/github-arc), the SECRET_PREFIX the secrets are named under and the reader role
    is scoped to, the IRSA provider the reader role trusts, and the signing mode (keyless clusters verify the image
    against signed_identity_subject, KMS-keyed clusters against the cosign-pub Secret). The node facts it also carries
    are unused: the runners' capacity is Karpenter NodePools the image ships, on the platform's EC2NodeClass default.
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    oidc_provider_arn = string
    oidc_issuer       = string
    secret_prefix     = string

    node_role_arn             = optional(string)
    node_subnet_ids           = optional(set(string), [])
    cluster_security_group_id = optional(string)

    version               = optional(string)
    endpoint              = optional(string)
    certificate_authority = optional(string)
    service_cidr          = optional(string)
  })
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[^/]+", var.cluster.platform_registry))
    error_message = "cluster.platform_registry must be an ECR prefix: <account>.dkr.ecr.<region>.amazonaws.com/<prefix> (is this a terraform-aws-eks-flux application_target?)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]*$", var.cluster.secret_prefix))
    error_message = "cluster.secret_prefix must use Secrets Manager name characters only ([A-Za-z0-9/_+=.@-])."
  }
}

variable "github" {
  description = <<-EOT
    Where the runners register, published as GITHUB_ARC_CONFIG_URL and GITHUB_ARC_RUNNER_GROUP.
      - config_url: the GitHub org (or enterprise, or repository) URL the scale sets register with, e.g.
        https://github.com/bitwise-media-group. The GitHub App whose credential the image syncs must be installed
        there with the organization permission "Self-hosted runners: read & write".
      - runner_group: the runner group both scale sets join; null joins the org's Default group.
  EOT
  type = object({
    config_url   = string
    runner_group = optional(string)
  })
  nullable = false

  validation {
    condition     = can(regex("^https://[^/]+/[^/]+(/[^/]+)?$", var.github.config_url))
    error_message = "github.config_url must be an https org, enterprise or repository URL (e.g. https://github.com/bitwise-media-group), with no trailing slash."
  }

  validation {
    condition     = var.github.runner_group == null || try(length(var.github.runner_group) > 0, false)
    error_message = "github.runner_group must be null (the Default group) or a non-empty group name."
  }
}

variable "runners" {
  description = <<-EOT
    The runner scale sets, keyed by architecture: amd64 (runs-on: linux-amd64) and arm64 (runs-on: linux-arm64). An
    absent key, or enabled = false, elects no scale set and no NodePool for that architecture. Each arch gets a
    dedicated scale-to-zero Karpenter NodePool github-arc-<arch> (shipped in the image, on EC2NodeClass default,
    tainted platform.bitwisemedia.uk/dedicated=github-arc:NoSchedule) that only its runner pods select; every field
    below reaches it as a GITHUB_ARC_<ARCH>_* var.
      - enabled: elect the arch (GITHUB_ARC_<ARCH>_ENABLED).
      - instance_families: the NodePool's karpenter.k8s.aws/instance-family requirement; null takes m7i,m7a for amd64
        and m7g,m8g for arm64, an empty set drops the requirement (any family of the arch).
      - capacity_types: karpenter.sh/capacity-type (on-demand, spot, reserved). on-demand by default: a reclaimed
        spot node kills its job.
      - max_nodes / cpu_limit / memory_limit: the NodePool's limits (nodes, cpu, memory).
      - max_runners: the scale set's ceiling (GITHUB_ARC_<ARCH>_MAX_RUNNERS); minRunners is always 0.
      - cpu / memory: the runner container's requests (GITHUB_ARC_<ARCH>_CPU / _MEMORY), sized so one runner fills a
        4 vCPU / 16 GiB instance.
      - consolidate_after: how long an empty runner node lingers before Karpenter removes it (consolidationPolicy is
        always WhenEmpty, so a running job is never evicted).
  EOT
  type = map(object({
    enabled           = optional(bool, true)
    instance_families = optional(set(string))
    capacity_types    = optional(set(string), ["on-demand"])
    max_nodes         = optional(number, 4)
    max_runners       = optional(number, 4)
    cpu               = optional(string, "3")
    memory            = optional(string, "10Gi")
    cpu_limit         = optional(string, "16")
    memory_limit      = optional(string, "64Gi")
    consolidate_after = optional(string, "5m")
  }))
  nullable = false
  default = {
    amd64 = {}
    arm64 = {}
  }

  validation {
    condition     = alltrue([for arch in keys(var.runners) : contains(["amd64", "arm64"], arch)])
    error_message = "runners keys must be architectures: amd64, arm64."
  }

  validation {
    condition     = alltrue([for runner in values(var.runners) : runner.max_runners >= 1 && runner.max_nodes >= 1])
    error_message = "runners max_runners and max_nodes must each be at least 1 (minimums are always 0: the NodePools and scale sets scale to zero)."
  }

  validation {
    condition = alltrue([
      for runner in values(var.runners) :
      length(runner.capacity_types) > 0 && alltrue([for type in runner.capacity_types : contains(["on-demand", "spot", "reserved"], type)])
    ])
    error_message = "runners capacity_types must be a non-empty set of on-demand, spot, reserved."
  }

  validation {
    condition = alltrue([
      for runner in values(var.runners) :
      can(regex("^[0-9]+(\\.[0-9]+)?m?$", runner.cpu)) && can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", runner.memory))
      && can(regex("^[0-9]+(\\.[0-9]+)?m?$", runner.cpu_limit)) && can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", runner.memory_limit))
    ])
    error_message = "runners cpu, memory, cpu_limit and memory_limit must be Kubernetes quantities (e.g. \"3\", \"3500m\", \"10Gi\")."
  }

  validation {
    condition     = alltrue([for runner in values(var.runners) : can(regex("^([0-9]+(s|m|h))+$|^Never$", runner.consolidate_after))])
    error_message = "runners consolidate_after must be a duration (e.g. 30s, 5m, 1h) or Never."
  }
}

variable "create_secrets" {
  description = <<-EOT
    Create the three Secrets Manager secrets (github-arc-app-id, github-arc-installation-id, github-arc-private-key,
    under cluster.secret_prefix). false expects secrets of those names to exist already (another root owns them); the
    read grant is identity-side either way - the sync KSA's IRSA reader role covers every secret under
    cluster.secret_prefix - so nothing else changes.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "manifests_semver" {
  description = <<-EOT
    The semver range the seed follows for this application's manifests image (version tags of
    oci://<cluster.platform_registry>/manifests/github-arc), published as GITHUB_ARC_MANIFESTS_SEMVER for the image's
    own ResourceSetInputProvider and as the seed's range. A range matching no tag empties the seed and prunes the
    application. Constraint order matters: a range must not start with '>'.
  EOT
  type        = string
  nullable    = false
  default     = "<1.0.0 >=0.1.0"

  validation {
    condition     = !startswith(var.manifests_semver, ">")
    error_message = "manifests_semver must not start with '>' - put the upper bound first (e.g. '<1.0.0 >=0.1.0')."
  }
}

variable "signed_identity_subject" {
  description = <<-EOT
    Fulcio certificate-subject regexp (keyless cosign) of the workflow that signs this application's manifests image -
    this repo's publish.yaml at a release tag by default. Published as SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS and used as
    the seed's verify subject. Ignored on KMS-keyed clusters (cluster.keyed), which verify against the signing key's
    public half instead.
  EOT
  type        = string
  nullable    = false
  default     = "^https://github\\.com/bitwise-media-group/github-arc-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
}

variable "extra_vars" {
  description = <<-EOT
    Further github-arc-vars keys merged beside the ones this module owns. Keys must be SCREAMING_SNAKE_CASE and must not
    be one of this module's own keys (GITHUB_ARC_*, SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS): set those through their own
    inputs.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.extra_vars) : can(regex("^[A-Z][A-Z0-9_]*$", key))])
    error_message = "extra_vars must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
  }

  validation {
    condition = alltrue([
      for key in keys(var.extra_vars) : !startswith(key, "GITHUB_ARC_") && key != "SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS"
    ])
    error_message = "extra_vars must not set a key this module owns (GITHUB_ARC_*, SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS) - use its input instead."
  }
}

variable "tags" {
  description = "Tags applied to every secret and to the secret-sync reader role."
  type        = map(string)
  nullable    = false
  default     = {}
}
