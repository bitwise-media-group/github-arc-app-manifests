# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# github-arc-app-manifests - self-hosted GitHub Actions runners (Actions
# Runner Controller scale sets, linux-amd64 and linux-arm64) as a
# self-owned application image for the platform clusters: the manifests are
# packaged as a cosign-signed OCI artifact
# (oci://<registry>/manifests/github-arc) that a cluster seeds once and flux
# owns from then on; the out-of-cluster halves (secret containers, IAM
# grants, GKE node pools, the seed itself) are the modules/{aws,google}
# terraform modules, which install github-arc onto a cluster through the
# cluster modules' modules/application.
#
# Everything lives in mise tasks: the shared toolchain submodule at .mise/
# provides the pinned tools, the common lint contract and the containers
# archetype's build and publish tasks (selected in the root mise.toml), and
# tasks.toml carries the validation surface. This Makefile is only the thin
# forwarding shim - `make <task>` == `mise run <task>`.
include .mise/archetypes/containers/include.mk
