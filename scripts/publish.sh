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

sign() { # sign <image@digest>; prints the transparency log index
  local out
  # cosign has no quiet flag, and keyless signing repeats its progress and
  # the sigstore terms of use on every image: hold the output back, show it
  # only when signing fails, and keep just the tlog index for forensics
  if ! out="$(cosign sign --yes --use-signing-config=false "$1" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  sed -n 's/^tlog entry created with index: //p' <<< "$out"
}

push() { # push <tag> <revision>
  local tag="$1" revision="$2" registry digest index
  for registry in $REGISTRIES; do
    digest="$(flux push artifact "oci://${registry}/${IMAGE}:${tag}" \
      --path "$ROOT/manifests" \
      --source "${SOURCE_URL:-https://github.com/bitwise-media-group/github-arc-app-manifests}" \
      --revision "$revision" \
      --output json | jq -r .digest)"
    index="$(sign "${registry}/${IMAGE}@${digest}")"
    echo "pushed ${registry}/${IMAGE}:${tag} (${digest}${index:+, tlog ${index}})"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "- \`${registry}/${IMAGE}:${tag}\` digest \`${digest}\`" >> "$GITHUB_STEP_SUMMARY"
    fi
  done
}

tag() { # tag <from> <to>
  local from="$1" to="$2" registry dest
  # global, not local: the EXIT trap fires after this function has returned
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/publish.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  for registry in $REGISTRIES; do
    # sanity: the source tag must exist (and be pullable) before the channel
    # moves; flux extracts into an existing directory only
    dest="$scratch/$registry"
    mkdir -p "$dest"
    flux pull artifact "oci://${registry}/${IMAGE}:${from}" --output "$dest" > /dev/null
    flux tag artifact "oci://${registry}/${IMAGE}:${from}" --tag "$to"
    echo "tagged ${registry}/${IMAGE}:${from} as ${to}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "- \`${registry}/${IMAGE}:${from}\` -> \`${to}\`" >> "$GITHUB_STEP_SUMMARY"
    fi
  done
}

case "${1:-}" in
  push) [[ $# -eq 3 ]] || usage; push "$2" "$3" ;;
  tag) [[ $# -eq 3 ]] || usage; tag "$2" "$3" ;;
  *) usage ;;
esac
