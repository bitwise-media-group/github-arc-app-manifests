# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Self-hosted GitHub Actions runners on Google Cloud, installed onto a
# terraform-google-gke-flux cluster as a self-contained application: the
# cluster root never learns github-arc exists. A root holding the cluster's
# application_target composes it:
#
#   module "github_arc" {
#     source  = ".../github-arc-app-manifests//modules/google"
#     cluster = data.terraform_remote_state.cluster.outputs.application_target
#     github  = { config_url = "https://github.com/bitwise-media-group" }
#   }
#
# Three things live here:
#
#   - one dedicated, scale-to-zero GKE node pool per elected architecture
#     (github-arc-<arch>, through the cluster module's modules/node-pool),
#     tainted so only the runner pods - which select it in the image's
#     google/scheduling.yaml - ever land on it;
#   - the three Secret Manager containers the image syncs into the
#     github-arc-github-app Secret (google/secrets.yaml), or with
#     create_secrets = false only their grants, each read resource-side by
#     the sync KSA's federated principal;
#   - everything that touches the cluster, through the cluster module's
#     modules/application: the seed (application-github-arc), the
#     github-arc-vars ConfigMap and the pre-created github-arc namespace.
#
# The credential VERSIONS are added out of band (gcloud secrets versions add
# - never terraform state), so destroying this module (with create_secrets)
# destroys them with the containers.

locals {
  # The image's runs-on labels are linux-<arch>; the node pools github-arc-<arch>.
  architectures = ["amd64", "arm64"]

  machine_types = {
    amd64 = "e2-standard-4"
    # Tau T2A (Ampere Altra): pd-backed, so the pool's boot disk needs no
    # hyperdisk the way C4A's would; offered in fewer zones than E2 (in
    # us-central1, zone a among others) - pin runners.arm64.node_locations
    # where the cluster's zones do not all carry it.
    arm64 = "t2a-standard-4"
  }

  # Every architecture, elected or not, so the vars below always carry both
  # (the manifests read every GITHUB_ARC_<ARCH>_* key bare); an absent key
  # is an unelected arch at the input defaults.
  runners = {
    for arch in local.architectures : arch => (
      contains(keys(var.runners), arch)
      ? merge(var.runners[arch], { machine_type = coalesce(var.runners[arch].machine_type, local.machine_types[arch]) })
      : {
        enabled        = false
        machine_type   = local.machine_types[arch]
        spot           = false
        max_nodes      = 4
        max_runners    = 4
        disk_size_gib  = 100
        cpu            = "3"
        memory         = "10Gi"
        node_locations = null
      }
    )
  }

  elected = { for arch, runner in local.runners : arch => runner if runner.enabled }

  # The application's own ConfigMap (github-arc-vars), substituted into the
  # manifests alongside cluster-vars: "true"/"false" literals for booleans,
  # the empty string for an unset runner group (the manifests gate the
  # chart's runnerGroup on it being non-empty).
  vars = merge(
    {
      GITHUB_ARC_CONFIG_URL   = var.github.config_url
      GITHUB_ARC_RUNNER_GROUP = var.github.runner_group != null ? var.github.runner_group : ""

    },
    merge([
      for arch, runner in local.runners : {
        "GITHUB_ARC_${upper(arch)}_ENABLED"     = runner.enabled ? "true" : "false"
        "GITHUB_ARC_${upper(arch)}_MAX_RUNNERS" = tostring(runner.max_runners)
        "GITHUB_ARC_${upper(arch)}_CPU"         = runner.cpu
        "GITHUB_ARC_${upper(arch)}_MEMORY"      = runner.memory
      }
    ]...),
  )

  # The GitHub App credential, one container per Secret key ARC reads. The
  # image's SecretProviderClass names exactly these under SECRET_PREFIX.
  containers = toset(["github-arc-app-id", "github-arc-installation-id", "github-arc-private-key"])

  wi_prefix = "principal://iam.googleapis.com/projects/${var.cluster.project_number}/locations/global/workloadIdentityPools/${var.cluster.workload_pool}/subject"

  # The KSA the image's SecretSync runs as (google/service-accounts.yaml).
  sync_member = "${local.wi_prefix}/ns/github-arc/sa/github-arc-secrets"
}

# One dedicated pool per elected architecture. Scale-to-zero (min and
# initial size 0, cluster-wide totals): a pending runner pod scales it up,
# and the autoscaler removes the node once the job's pod is gone. The taint
# keeps every other workload - node auto-provisioning's included - off the
# privileged runners' nodes; GKE adds kubernetes.io/arch=arm64:NoSchedule
# to the Arm pool by itself, which the image's arm64 scheduling tolerates.
module "node_pool" {
  source   = "git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/node-pool?ref=223fab7691bf460fcc04c5f0991f76b9f23e640d"
  for_each = local.elected

  project  = var.cluster.project
  cluster  = var.cluster.name
  location = var.cluster.location
  name     = "github-arc-${each.key}"

  service_account = var.cluster.node_service_account
  node_locations  = each.value.node_locations != null ? each.value.node_locations : var.cluster.node_locations

  machine_type  = each.value.machine_type
  spot          = each.value.spot
  disk_size_gib = each.value.disk_size_gib

  min_size     = 0
  initial_size = 0
  max_size     = each.value.max_nodes
  # spot chases spare capacity across zones; on-demand keeps GKE's default
  location_policy = each.value.spot ? "ANY" : null

  labels = {
    "platform.bitwisemedia.uk/node-pool" = "github-arc-${each.key}"
  }

  taints = [
    {
      key    = "platform.bitwisemedia.uk/dedicated"
      value  = "github-arc"
      effect = "NO_SCHEDULE"
    },
  ]

  resource_labels = var.labels
}

resource "google_secret_manager_secret" "main" {
  for_each = var.create_secrets ? local.containers : toset([])

  project   = var.cluster.project
  secret_id = "${var.cluster.secret_prefix}${each.key}"
  labels    = var.labels

  replication {
    auto {}
  }
}

# Accessor only: the sync KSA reads versions, nothing else. Version WRITES
# stay a human/out-of-band concern. Without create_secrets the grant names
# the existing container directly - the same id the image syncs.
resource "google_secret_manager_secret_iam_member" "sync" {
  for_each = local.containers

  project   = var.cluster.project
  secret_id = var.create_secrets ? google_secret_manager_secret.main[each.key].secret_id : "${var.cluster.secret_prefix}${each.key}"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.sync_member
}

# The cluster-facing half, through the cluster module's own standalone
# application module: every name it mints (release application-github-arc,
# ConfigMap github-arc-vars) is the one the manifests expect.
module "application" {
  source = "git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/application?ref=223fab7691bf460fcc04c5f0991f76b9f23e640d"

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
    # mirrors the image's own Kustomization: GKE ships its secret sync with
    # the cluster, so there is no secret-sync Kustomization to wait on, and
    # no karpenter - the node pools above are terraform's
    depends_on = ["kyverno-policies", "arc"]
    # keyless clusters pin this repo's publish identity; KMS-keyed clusters
    # verify against the cosign-pub Secret instead
    verify = {
      subject = var.cluster.keyed ? null : var.signed_identity_subject
      keyed   = var.cluster.keyed
    }
  }

  vars       = merge(var.extra_vars, local.vars)
  namespaces = ["github-arc"]
}
