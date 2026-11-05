#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Publish the github-arc manifests image to every platform registry.
#
#   publish.sh push <tag> <revision>   push manifests/ as oci://<registry>/manifests/github-arc:<tag>,
#                                      cosign-sign the digest, per registry in $REGISTRIES
#   publish.sh tag <from> <to>         move a channel tag (<to>) onto an already published <from>,
#                                      per registry, after a pull sanity check
#
# REGISTRIES is a space-separated list of registry prefixes (host/prefix, no
# scheme): the GAR platform registry, the ECR platform registry, or both. The
# workflows log docker in to each host before calling this, so flux push and
# cosign read the keychain. Signing is keyless: the Fulcio certificate subject
# is the calling workflow at its ref, which is what the seed's OCIRepository
# verify block (SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS) matches on every cluster.
# cosign v3 stores the signature as a sigstore bundle via the OCI referrers
# API; --use-signing-config=false only pins the v2 trust services (Fulcio +
# Rekor v1), it does not change the format.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="manifests/github-arc"

usage() {
  echo "usage: $0 push <tag> <revision> | tag <from> <to>" >&2
  exit 2
}

[[ -n "${REGISTRIES:-}" ]] || { echo "REGISTRIES must list at least one registry prefix" >&2; exit 2; }

push() { # push <tag> <revision>
  local tag="$1" revision="$2" registry digest
  for registry in $REGISTRIES; do
    digest="$(flux push artifact "oci://${registry}/${IMAGE}:${tag}" \
      --path "$ROOT/manifests" \
      --source "${SOURCE_URL:-https://github.com/bitwise-media-group/github-arc-app-manifests}" \
      --revision "$revision" \
      --output json | jq -r .digest)"
    cosign sign --yes --use-signing-config=false "${registry}/${IMAGE}@${digest}"
    echo "pushed ${registry}/${IMAGE}:${tag} (${digest})"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "- \`${registry}/${IMAGE}:${tag}\` digest \`${digest}\`" >> "$GITHUB_STEP_SUMMARY"
    fi
  done
}

tag() { # tag <from> <to>
  local from="$1" to="$2" registry scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/publish.XXXXXX")"
  for registry in $REGISTRIES; do
    # sanity: the source tag must exist (and be pullable) before the channel moves
    flux pull artifact "oci://${registry}/${IMAGE}:${from}" --output "$scratch/$from" > /dev/null
    flux tag artifact "oci://${registry}/${IMAGE}:${from}" --tag "$to"
    echo "tagged ${registry}/${IMAGE}:${from} as ${to}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "- \`${registry}/${IMAGE}:${from}\` -> \`${to}\`" >> "$GITHUB_STEP_SUMMARY"
    fi
  done
  rm -rf "$scratch"
}

case "${1:-}" in
  push) [[ $# -eq 3 ]] || usage; push "$2" "$3" ;;
  tag) [[ $# -eq 3 ]] || usage; tag "$2" "$3" ;;
  *) usage ;;
esac
