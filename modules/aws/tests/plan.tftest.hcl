# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked aws and helm providers: the default
# election (both architectures), a single-arch election, the
# create_secrets = false shape, and the vars contract - every key the
# manifests substitute (tests/github-arc-vars.env plus
# tests/github-arc-vars.aws.env) is emitted.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "helm" {}

variables {
  # terraform-aws-eks-flux's application_target, as a cluster root exports it
  cluster = {
    name              = "ci-test"
    namespace         = "flux-system"
    platform_registry = "111111111111.dkr.ecr.eu-west-2.amazonaws.com/platform"
    tree              = "aws"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLE"
    oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLE"
    secret_prefix     = "ci-test-"
  }

  github = {
    config_url = "https://github.com/bitwise-media-group"
  }
}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(output.node_pools)) == tolist(["amd64", "arm64"]) && output.node_pools["arm64"].name == "github-arc-arm64"
    error_message = "the default election is both architectures, one NodePool github-arc-<arch> each"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_ENABLED == "true" && output.vars.GITHUB_ARC_ARM64_ENABLED == "true"
    error_message = "both scale sets are elected by default"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_INSTANCE_FAMILIES == "m7i,m7a" && output.vars.GITHUB_ARC_ARM64_INSTANCE_FAMILIES == "m7g,m8g"
    error_message = "unset instance families take the per-arch defaults"
  }

  assert {
    condition     = sort([for secret in values(aws_secretsmanager_secret.main) : secret.name]) == tolist(["ci-test-github-arc-app-id", "ci-test-github-arc-installation-id", "ci-test-github-arc-private-key"])
    error_message = "the default creates exactly the GitHub App trio under the cluster's SECRET_PREFIX - the names the image syncs"
  }

  assert {
    condition     = keys(output.secret_reader_roles) == ["github-arc/github-arc-secrets"]
    error_message = "the sync KSA github-arc/github-arc-secrets gets the podless IRSA reader role the image's annotation names"
  }
}

run "vars_contract" {
  command = plan

  # exactly the keys tests/github-arc-vars.env + github-arc-vars.aws.env
  # carry - the set the manifests substitute bare, which the harness renders
  # strictly
  assert {
    condition = sort(keys(output.vars)) == tolist([
      "GITHUB_ARC_AMD64_CAPACITY_TYPES", "GITHUB_ARC_AMD64_CONSOLIDATE_AFTER", "GITHUB_ARC_AMD64_CPU",
      "GITHUB_ARC_AMD64_CPU_LIMIT", "GITHUB_ARC_AMD64_ENABLED", "GITHUB_ARC_AMD64_INSTANCE_FAMILIES",
      "GITHUB_ARC_AMD64_MAX_NODES", "GITHUB_ARC_AMD64_MAX_RUNNERS", "GITHUB_ARC_AMD64_MEMORY",
      "GITHUB_ARC_AMD64_MEMORY_LIMIT",
      "GITHUB_ARC_ARM64_CAPACITY_TYPES", "GITHUB_ARC_ARM64_CONSOLIDATE_AFTER", "GITHUB_ARC_ARM64_CPU",
      "GITHUB_ARC_ARM64_CPU_LIMIT", "GITHUB_ARC_ARM64_ENABLED", "GITHUB_ARC_ARM64_INSTANCE_FAMILIES",
      "GITHUB_ARC_ARM64_MAX_NODES", "GITHUB_ARC_ARM64_MAX_RUNNERS", "GITHUB_ARC_ARM64_MEMORY",
      "GITHUB_ARC_ARM64_MEMORY_LIMIT",
      "GITHUB_ARC_CONFIG_URL", "GITHUB_ARC_RUNNER_GROUP",
    ])
    error_message = "github-arc-vars must carry exactly the keys the manifests consume"
  }

  assert {
    condition = (
      output.vars.GITHUB_ARC_AMD64_CAPACITY_TYPES == "on-demand"
      && output.vars.GITHUB_ARC_AMD64_CPU_LIMIT == "16"
      && output.vars.GITHUB_ARC_AMD64_MEMORY_LIMIT == "64Gi"
      && output.vars.GITHUB_ARC_AMD64_MAX_NODES == "4"
      && output.vars.GITHUB_ARC_AMD64_CONSOLIDATE_AFTER == "5m"
      && output.vars.GITHUB_ARC_ARM64_MAX_RUNNERS == "4"
      && output.vars.GITHUB_ARC_RUNNER_GROUP == ""
    )
    error_message = "the defaults must match the harness fixtures (tests/github-arc-vars*.env)"
  }
}

run "application_seed" {
  command = plan

  assert {
    condition     = output.release == "application-github-arc"
    error_message = "the seed is release application-github-arc, the release that owns the github-arc-manifests seed on every apply"
  }

  assert {
    condition     = module.application.tag_provider == "ECRArtifactTag" && module.application.oci_provider == "aws"
    error_message = "the image lives beneath the platform registry, so its tags are listed through the ECR API and pulled as provider aws"
  }

  assert {
    condition     = module.application.path == "./aws"
    error_message = "the seed applies the image's aws tree"
  }
}

run "single_arch" {
  command = plan

  variables {
    runners = {
      arm64 = { capacity_types = ["spot", "on-demand"], instance_families = [], max_runners = 2 }
    }
  }

  assert {
    condition     = keys(output.node_pools) == ["arm64"]
    error_message = "an absent architecture renders no NodePool"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_ENABLED == "false" && output.vars.GITHUB_ARC_ARM64_ENABLED == "true"
    error_message = "an absent architecture publishes ENABLED=false, so the image renders neither scale set nor NodePool for it"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_AMD64_INSTANCE_FAMILIES == "m7i,m7a" && output.vars.GITHUB_ARC_AMD64_MAX_NODES == "4"
    error_message = "an absent architecture still publishes every key - the manifests read them bare"
  }

  assert {
    condition     = output.vars.GITHUB_ARC_ARM64_CAPACITY_TYPES == "on-demand,spot" && output.vars.GITHUB_ARC_ARM64_INSTANCE_FAMILIES == ""
    error_message = "capacity types publish comma-joined and sorted; an empty family set publishes empty (no family requirement)"
  }
}

run "existing_secrets" {
  command = plan

  variables {
    create_secrets = false
  }

  assert {
    condition     = length(aws_secretsmanager_secret.main) == 0
    error_message = "create_secrets = false creates no secrets"
  }

  assert {
    condition     = keys(output.secret_reader_roles) == ["github-arc/github-arc-secrets"]
    error_message = "the identity-side read grant (the reader role over SECRET_PREFIX*) stays"
  }

  assert {
    condition     = output.secrets["github-arc-app-id"].name == "ci-test-github-arc-app-id" && output.secrets["github-arc-app-id"].arn == null
    error_message = "the secrets output still names every secret the image syncs"
  }
}

run "extra_vars_cannot_shadow" {
  command = plan

  variables {
    extra_vars = { GITHUB_ARC_CONFIG_URL = "https://example.com" }
  }

  expect_failures = [var.extra_vars]
}

run "bad_capacity_type_rejected" {
  command = plan

  variables {
    runners = { amd64 = { capacity_types = ["preemptible"] } }
  }

  expect_failures = [var.runners]
}

run "foreign_registry_rejected" {
  command = plan

  variables {
    cluster = {
      name              = "ci-test"
      namespace         = "flux-system"
      platform_registry = "ghcr.io/bitwise-media-group"
      tree              = "aws"
      issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
      keyed             = false
      oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLE"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLE"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.cluster]
}

run "image_follows_the_edge_channel" {
  command = plan

  variables {
    image = { channel = "edge", semver = "^0.2.0-0" }
  }

  assert {
    condition     = output.release == "application-github-arc"
    error_message = "a bounded edge channel passes straight through to the seed"
  }
}
