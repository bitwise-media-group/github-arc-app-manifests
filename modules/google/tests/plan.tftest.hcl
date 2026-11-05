# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked google and helm providers: the
# default election (both architectures), a single-arch election, the
# create_secrets = false grants-only shape, and the vars contract - every
# key the manifests substitute (tests/github-arc-vars.env) is emitted.

mock_provider "google" {}

mock_provider "helm" {}

variables {
  # terraform-google-gke-flux's application_target, as a cluster root exports it
  cluster = {
    name              = "ci-test"
    namespace         = "flux-system"
    platform_registry = "us-central1-docker.pkg.dev/ci-test-project/platform"
    tree              = "google"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    project           = "ci-test-project"
    project_number    = "111111111111"
    workload_pool     = "ci-test-project.svc.id.goog"
    secret_prefix     = "ci-test-"

    location             = "us-central1"
    node_locations       = ["us-central1-a", "us-central1-b"]
    node_service_account = "ci-test-nodes@ci-test-project.iam.gserviceaccount.com"
  }

  github = {
    config_url = "https://github.com/bitwise-media-group"
  }
}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(module.node_pool)) == tolist(["amd64", "arm64"])
    error_message = "the default election is both architectures, one node pool each"
  }

  assert {
    condition     = output.node_pools["amd64"].name == "github-arc-amd64" && output.node_pools["arm64"].name == "github-arc-arm64"
    error_message = "the pools are github-arc-<arch>, the names the image's scheduling selects (cloud.google.com/gke-nodepool)"
  }

  assert {
    condition     = output.node_pools["arm64"].labels["platform.bitwisemedia.uk/node-pool"] == "github-arc-arm64"
    error_message = "every pool carries its platform.bitwisemedia.uk/node-pool label"
  }

  assert {
    condition     = local.elected["amd64"].machine_type == "e2-standard-4" && local.elected["arm64"].machine_type == "t2a-standard-4"
    error_message = "amd64 defaults to e2-standard-4 and arm64 to t2a-standard-4"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_ENABLED == "true" && output.vars.GITHUB_ARC_ARM64_ENABLED == "true"
    error_message = "both scale sets are elected by default"
  }

  assert {
    condition     = sort(keys(google_secret_manager_secret.main)) == tolist(["github-arc-app-id", "github-arc-installation-id", "github-arc-private-key"])
    error_message = "the default creates exactly the GitHub App trio"
  }

  assert {
    condition     = alltrue([for secret in values(google_secret_manager_secret.main) : secret.project == "ci-test-project" && startswith(secret.secret_id, "ci-test-")])
    error_message = "the containers live in the cluster's project under its SECRET_PREFIX - the ids the image syncs"
  }

  assert {
    condition = alltrue([
      for member in values(google_secret_manager_secret_iam_member.sync) :
      member.role == "roles/secretmanager.secretAccessor"
      && member.member == "principal://iam.googleapis.com/projects/111111111111/locations/global/workloadIdentityPools/ci-test-project.svc.id.goog/subject/ns/github-arc/sa/github-arc-secrets"
    ])
    error_message = "every container is read by the github-arc/github-arc-secrets KSA as a federated principal in the cluster's pool"
  }
}

run "vars_contract" {
  command = plan

  # exactly the keys tests/github-arc-vars.env carries - the set the
  # manifests substitute bare, which the harness renders strictly
  assert {
    condition = sort(keys(output.vars)) == tolist([
      "GITHUB_ARC_AMD64_CPU", "GITHUB_ARC_AMD64_ENABLED", "GITHUB_ARC_AMD64_MAX_RUNNERS", "GITHUB_ARC_AMD64_MEMORY",
      "GITHUB_ARC_ARM64_CPU", "GITHUB_ARC_ARM64_ENABLED", "GITHUB_ARC_ARM64_MAX_RUNNERS", "GITHUB_ARC_ARM64_MEMORY",
      "GITHUB_ARC_CONFIG_URL", "GITHUB_ARC_MANIFESTS_SEMVER", "GITHUB_ARC_RUNNER_GROUP",
      "SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS",
    ])
    error_message = "github-arc-vars must carry exactly the keys the manifests consume"
  }

  assert {
    condition = (
      output.vars.GITHUB_ARC_CONFIG_URL == "https://github.com/bitwise-media-group"
      && output.vars.GITHUB_ARC_RUNNER_GROUP == ""
      && output.vars.GITHUB_ARC_AMD64_MAX_RUNNERS == "4"
      && output.vars.GITHUB_ARC_AMD64_CPU == "3"
      && output.vars.GITHUB_ARC_AMD64_MEMORY == "10Gi"
      && output.vars.GITHUB_ARC_MANIFESTS_SEMVER == "<1.0.0 >=0.1.0"
    )
    error_message = "the defaults must match the harness fixture (tests/github-arc-vars.env)"
  }
}

run "application_seed" {
  command = plan

  assert {
    condition     = output.release == "application-github-arc"
    error_message = "the seed is release application-github-arc, the name the image's flux/ objects are adopted from"
  }

  assert {
    condition     = module.application.tag_provider == "GARArtifactTag" && module.application.oci_provider == "gcp"
    error_message = "the image lives beneath the platform registry, so its tags are listed through the Artifact Registry API and pulled as provider gcp"
  }

  assert {
    condition     = module.application.path == "./deploy/google"
    error_message = "the seed applies the image's google tree"
  }
}

run "single_arch" {
  command = plan

  variables {
    runners = {
      arm64 = { max_runners = 2, max_nodes = 2, spot = true, node_locations = ["us-central1-a"] }
    }
    github = {
      config_url   = "https://github.com/bitwise-media-group"
      runner_group = "platform-ci"
    }
  }

  assert {
    condition     = keys(module.node_pool) == ["arm64"]
    error_message = "an absent architecture gets no node pool"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_ENABLED == "false" && output.vars.GITHUB_ARC_ARM64_ENABLED == "true"
    error_message = "an absent architecture publishes ENABLED=false, so the image renders no scale set for it"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_MAX_RUNNERS == "4" && output.vars.GITHUB_ARC_AMD64_CPU == "3"
    error_message = "an absent architecture still publishes every key - the manifests read them bare"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_ARM64_MAX_RUNNERS == "2" && output.vars.GITHUB_ARC_RUNNER_GROUP == "platform-ci"
    error_message = "the configured ceiling and runner group are published"
  }
}

run "disabled_arch" {
  command = plan

  variables {
    runners = {
      amd64 = {}
      arm64 = { enabled = false }
    }
  }

  assert {
    condition     = keys(module.node_pool) == ["amd64"] && output.vars.GITHUB_ARC_ARM64_ENABLED == "false"
    error_message = "enabled = false elects neither the pool nor the scale set"
  }
}

run "existing_secrets" {
  command = plan

  variables {
    create_secrets = false
  }

  assert {
    condition     = length(google_secret_manager_secret.main) == 0
    error_message = "create_secrets = false creates no containers"
  }

  assert {
    condition = (
      sort([for member in values(google_secret_manager_secret_iam_member.sync) : member.secret_id])
      == tolist(["ci-test-github-arc-app-id", "ci-test-github-arc-installation-id", "ci-test-github-arc-private-key"])
    )
    error_message = "the grants name the existing containers directly, under the cluster's SECRET_PREFIX"
  }

  assert {
    condition     = output.secrets["github-arc-private-key"].id == "projects/ci-test-project/secrets/ci-test-github-arc-private-key" && !output.secrets["github-arc-private-key"].created
    error_message = "the secrets output still names every container"
  }
}

run "extra_vars_cannot_shadow" {
  command = plan

  variables {
    extra_vars = { GITHUB_ARC_AMD64_ENABLED = "false" }
  }

  expect_failures = [var.extra_vars]
}

run "unknown_architecture_rejected" {
  command = plan

  variables {
    runners = { riscv64 = {} }
  }

  expect_failures = [var.runners]
}

run "keyed_cluster" {
  command = plan

  variables {
    cluster = {
      name              = "ci-test"
      namespace         = "flux-system"
      platform_registry = "us-central1-docker.pkg.dev/ci-test-project/platform"
      tree              = "google"
      keyed             = true
      project           = "ci-test-project"
      project_number    = "111111111111"
      workload_pool     = "ci-test-project.svc.id.goog"
      secret_prefix     = ""

      location             = "us-central1"
      node_service_account = "ci-test-nodes@ci-test-project.iam.gserviceaccount.com"
    }
  }

  # modules/application refuses a keyless subject on a keyed cluster without
  # an explicit issuer; reaching a plan proves the seed switched to keyed.
  assert {
    condition     = output.release == "application-github-arc"
    error_message = "a KMS-keyed cluster must seed github-arc verified against the cosign-pub Secret"
  }
}
