# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster" {
  description = <<-EOT
    The cluster to install github-arc onto: pass terraform-google-gke-flux's application_target output verbatim
    (through terraform_remote_state or any other channel). It is handed to that repo's modules/application
    unchanged, and supplies the project the containers and node pools live in, the platform registry the image is
    published beneath (oci://<platform_registry>/manifests/github-arc), the SECRET_PREFIX the containers are named
    under, the project number and Workload Identity pool the sync KSA's federated principal is composed from, the
    signing mode (keyless clusters verify the image against signed_identity_subject, KMS-keyed clusters against the
    cosign-pub Secret), and the node facts every runner node pool is built from (location, node_locations,
    node_service_account).
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    project           = string
    project_number    = string
    workload_pool     = string
    secret_prefix     = string

    location             = string
    node_locations       = optional(set(string), [])
    node_service_account = string
  })
  nullable = false

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.cluster.platform_registry))
    error_message = "cluster.platform_registry must be an Artifact Registry docker repository prefix: <location>-docker.pkg.dev/<project>/<repository> (is this a terraform-google-gke-flux application_target?)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*$", var.cluster.secret_prefix))
    error_message = "cluster.secret_prefix must use Secret Manager id characters only ([A-Za-z0-9_-])."
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
    absent key, or enabled = false, elects no scale set and no node pool for that architecture. Each arch gets a
    dedicated scale-to-zero GKE node pool github-arc-<arch> (min 0, tainted platform.bitwisemedia.uk/dedicated=
    github-arc:NoSchedule) that only its runner pods select.
      - enabled: elect the arch (GITHUB_ARC_<ARCH>_ENABLED).
      - machine_type: the pool's machine type; e2-standard-4 for amd64, t2a-standard-4 for arm64 (T2A is pd-backed and
        offered in fewer zones than E2 - see node_locations; C4A would need hyperdisk).
      - spot: run the pool on Spot VMs (location policy ANY). Off by default: a preempted node kills its job.
      - max_nodes: the pool's ceiling, a cluster-wide total.
      - max_runners: the scale set's ceiling (GITHUB_ARC_<ARCH>_MAX_RUNNERS); minRunners is always 0.
      - disk_size_gib: each node's boot disk, which holds every image a dind job pulls or builds.
      - cpu / memory: the runner container's requests (GITHUB_ARC_<ARCH>_CPU / _MEMORY). The defaults fill one 4 vCPU /
        16 GiB node, so exactly one runner lands per node and max_nodes = max_runners.
      - node_locations: zones for this pool only; null takes cluster.node_locations (empty inherits the cluster's).
  EOT
  type = map(object({
    enabled        = optional(bool, true)
    machine_type   = optional(string)
    spot           = optional(bool, false)
    max_nodes      = optional(number, 4)
    max_runners    = optional(number, 4)
    disk_size_gib  = optional(number, 100)
    cpu            = optional(string, "3")
    memory         = optional(string, "10Gi")
    node_locations = optional(set(string))
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
    error_message = "runners max_runners and max_nodes must each be at least 1 (minimums are always 0: the pools and scale sets scale to zero)."
  }

  validation {
    condition = alltrue([
      for runner in values(var.runners) :
      can(regex("^[0-9]+(\\.[0-9]+)?m?$", runner.cpu)) && can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", runner.memory))
    ])
    error_message = "runners cpu and memory must be Kubernetes quantities (e.g. cpu \"3\" or \"3500m\", memory \"10Gi\")."
  }
}

variable "create_secrets" {
  description = <<-EOT
    Create the three Secret Manager containers (github-arc-app-id, github-arc-installation-id, github-arc-private-key,
    under cluster.secret_prefix in cluster.project). false grants the sync KSA accessor on containers of those names
    that already exist (another root owns them) instead of creating them - the grants are resource-side, so they
    still need the names.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "manifests_semver" {
  description = "The semver range the seed follows for the manifests image (GITHUB_ARC_MANIFESTS_SEMVER); a range matching no tag prunes the application."
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
    Fulcio certificate-subject regexp of the workflow that signs the manifests image
    (SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS, and the seed's verify subject); this repo's release.yaml on main by default,
    which signs edge builds and (by promotion) every release. Ignored on KMS-keyed clusters (cluster.keyed), which verify against the signing key's public half instead.
  EOT
  type        = string
  nullable    = false
  default     = "^https://github\\.com/bitwise-media-group/github-arc-app-manifests/\\.github/workflows/release\\.yaml@refs/heads/main$"
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

variable "labels" {
  description = "Labels applied to every secret container and, as GCP resource labels, to every runner node."
  type        = map(string)
  nullable    = false
  default     = {}
}
