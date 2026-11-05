#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Render and validate everything a cluster would apply from this image, once
# per deploy tree and signing mode ({aws,google} x {keyless,keyed}):
#   1. kustomize-build the deploy tree (common + flux + the cloud overlay)
#   2. substitute cluster-vars AND github-arc-vars the way the seeded
#      Kustomization does (postBuild.substituteFrom), faithfully to the
#      controller's roundtrip - so an empty var that would become null on a
#      cluster becomes null (and fails) here, and a var neither ConfigMap
#      publishes fails strict substitution
#   3. render every ResourceSet with sample inputs (flux-operator CLI)
#   4. kubeconform the results against Flux + flux-operator + CRD schemas
# plus the seed-contract guard (the flux/ objects must carry exactly the
# names, namespace and prune label the modules/application seed creates)
# and the runner guard (every runner-pod image comes from the platform
# mirror, and exactly the elected architectures render a scale set - and,
# on aws, a NodePool).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

# kustomize-controller substitutes in STRICT mode: a bare ${VAR} fails the
# whole Kustomization on any cluster whose ConfigMaps never publish VAR (a
# ${VAR:=default} never does). Mirror that here so each tree's pass, run
# under only that cloud's env plus github-arc-vars, fails the way the cluster
# would.
check_strict() { # check_strict <in-file>
  local var
  # shellcheck disable=SC2016 # the dollar-brace is the grep pattern, not an expansion
  while IFS= read -r var; do
    [[ -n "${!var+x}" ]] || { echo "strict substitution: \${$var} in $1 but $var is not set in the env" >&2; exit 1; }
  done < <(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$1" | tr -d '${}' | sort -u)
}

# After substitution, no path that held a ${VAR}-bearing string may hold
# null: that is exactly the cluster failure mode where the controller's
# roundtrip strips redundant quotes and an empty value re-parses as null.
null_guard() { # null_guard <pre-file> <post-file>
  local pre nulls hits
  # shellcheck disable=SC2016 # yq expressions, not shell expansions
  pre="$(yq ea '.. | select(tag == "!!str") | select(test("\$\{[A-Z]")) | ([document_index] + path | join("/"))' "$1" | sort -u)"
  nulls="$(yq ea '.. | select(tag == "!!null") | ([document_index] + path | join("/"))' "$2" | sort -u)"
  hits="$(comm -12 <(printf '%s\n' "$pre") <(printf '%s\n' "$nulls") | grep -v '^$' || true)"
  if [[ -n "$hits" ]]; then
    {
      echo "null substitution in $2 - these \${VAR}-bearing scalars became null (doc/path):"
      printf '%s\n' "$hits" | sed 's/^/  /'
      echo "gate the key absent, use << \"\${VAR:=}\" | quote >>, or move it into a resourcesTemplate block"
    } >&2
    exit 1
  fi
}

# Substitute vars the way kustomize-controller's postBuild does: parse,
# re-serialize (redundant quotes drop), TEXTUALLY envsubst, re-parse. yq's
# envsubst also eats bare $VAR (dex's $-refs, Go template $variables) where
# the controller only substitutes the braced form - shield those behind a
# sentinel so the render matches the cluster.
substitute() { # substitute <in-file> <out-file>
  check_strict "$1"
  # shellcheck disable=SC2016 # yq expression
  yq ea '(.. | select(kind == "scalar")) style=""' "$1" > "$2.norm"
  # shellcheck disable=SC2016 # ${1} and $$ are yq syntax; single quotes are deliberate
  IN_FILE="$2.norm" yq -n 'load_str(strenv(IN_FILE)) | sub("\$([^{])"; "@BARE_DOLLAR@${1}") | envsubst | sub("@BARE_DOLLAR@"; "$$")' > "$2"
  null_guard "$2.norm" "$2"
  rm -f "$2.norm"
}

null_guard_selftest() {
  local dir="$BUILD/selftest"
  mkdir -p "$dir"
  cat > "$dir/canary.yaml" <<'YAML'
canary:
  trip: "${VALIDATE_SELFTEST_EMPTY}"
  control: "${VALIDATE_SELFTEST_PRESENT}"
YAML
  export VALIDATE_SELFTEST_EMPTY="" VALIDATE_SELFTEST_PRESENT="present"
  if (substitute "$dir/canary.yaml" "$dir/canary.out.yaml") 2> /dev/null; then
    echo "self-test: null_guard did NOT trip on an empty-var quoted scalar - the guard has rotted, aborting" >&2
    exit 1
  fi
  export VALIDATE_SELFTEST_EMPTY="non-empty"
  substitute "$dir/canary.yaml" "$dir/canary.out.yaml" \
    || { echo "self-test: substitute failed its positive control" >&2; exit 1; }
  unset VALIDATE_SELFTEST_EMPTY VALIDATE_SELFTEST_PRESENT
  rm -rf "$dir"
}

# The seed contract: modules/application creates a ResourceSetInputProvider
# and a ResourceSet named github-arc-manifests in flux-system, and the
# ResourceSet emits Kustomization/github-arc; this image ships the same objects
# so the Kustomization adopts them. A drift here is silent on a cluster
# (two providers, two Kustomizations, an orphaned seed), so it is asserted.
check_seed_contract() {
  local built="$1" kinds
  kinds="$(yq 'select(.kind == "ResourceSetInputProvider" or .kind == "ResourceSet") | select(.metadata.namespace == "flux-system") | .kind + "/" + .metadata.name + "@" + (.metadata.labels["kustomize.toolkit.fluxcd.io/prune"] // "prunable")' "$built" | grep -v '^---$' | sort | tr '\n' ' ')"
  [[ "$kinds" == "ResourceSet/github-arc-manifests@disabled ResourceSetInputProvider/github-arc-manifests@disabled " ]] \
    || { echo "seed contract: flux-system must carry exactly RSIP + ResourceSet github-arc-manifests, both prune-disabled; got: $kinds" >&2; exit 1; }
  yq 'select(.kind == "ResourceSet" and .metadata.name == "github-arc-manifests") | .spec.resourcesTemplate' "$built" \
    | grep -q '^  name: github-arc$' \
    || { echo "seed contract: ResourceSet/github-arc-manifests must emit Kustomization/github-arc" >&2; exit 1; }
}

# Every ResourceSet-bearing source file needs a fixture at
# tests/inputs/<flux|common|tree>/<file>[.<variant>].yaml; each variant
# renders the same ResourceSet with a different input set.
render_resourcesets() { # render_resourcesets <tree> <out-dir>
  local tree="$1" out="$2" src scope file inputs variant vbase
  for src in "$ROOT/manifests/flux"/*.yaml "$ROOT/manifests/deploy/common"/*.yaml "$ROOT/manifests/deploy/$tree"/*.yaml; do
    grep -q '^kind: ResourceSet$' "$src" || continue
    scope="$(basename "$(dirname "$src")")"
    file="$(basename "$src" .yaml)"
    substitute "$src" "$out/src-$scope-$file.yaml"
    yq 'select(.kind == "ResourceSet")' "$out/src-$scope-$file.yaml" > "$out/rs-$scope-$file.yaml"
    [[ -f "$ROOT/tests/inputs/$scope/$file.yaml" ]] || { echo "missing test inputs tests/inputs/$scope/$file.yaml for $src" >&2; exit 1; }
    for inputs in "$ROOT/tests/inputs/$scope/$file"*.yaml; do
      vbase="$(basename "$inputs" .yaml)"
      [[ "$vbase" =~ ^${file}(\.[A-Za-z0-9-]+)?$ ]] || continue
      variant="$vbase"
      if ! flux-operator build resourceset -f "$out/rs-$scope-$file.yaml" --inputs-from "$inputs" \
        > "$out/rendered-$scope-$variant.yaml" 2> "$out/rendered-$scope-$variant.err"; then
        grep -q "no objects were generated" "$out/rendered-$scope-$variant.err" \
          || { cat "$out/rendered-$scope-$variant.err" >&2; exit 1; }
        : > "$out/rendered-$scope-$variant.yaml"
      fi
      rm -f "$out/rendered-$scope-$variant.err"
    done
  done
}

# The runner guard. verify-platform-signature admits only mirrored images,
# and the scale-set chart's own dind template would reach Docker Hub - so
# every image the rendered scale sets name must sit under the platform
# mirror. And the per-arch gate must hold: exactly the architectures whose
# GITHUB_ARC_<ARCH>_ENABLED is "true" render a HelmRelease linux-<arch>
# (plus, on aws, a NodePool github-arc-<arch>).
check_runners() { # check_runners <tree> <out-dir>
  local tree="$1" out="$2" rendered="$2/rendered-common-resourceset.yaml" arch want got images foreign
  images="$(yq 'select(.kind == "HelmRelease") | .spec.values.template.spec | (.initContainers[], .containers[]) | .image' "$rendered" | grep -v '^---$' | sort -u)"
  [[ -n "$images" ]] || { echo "runner guard: no runner images rendered in $rendered" >&2; exit 1; }
  foreign="$(printf '%s\n' "$images" | grep -v "^${CONTAINER_REGISTRY}/images/" || true)"
  [[ -z "$foreign" ]] || { echo "runner guard: runner images outside the platform mirror: $foreign" >&2; exit 1; }
  want=""
  for arch in amd64 arm64; do
    local var; var="GITHUB_ARC_$(tr '[:lower:]' '[:upper:]' <<<"$arch")_ENABLED"
    [[ "${!var}" == "true" ]] && want+="linux-$arch "
  done
  got="$(yq 'select(.kind == "HelmRelease") | .metadata.name' "$rendered" | grep -v '^---$' | sort | tr '\n' ' ')"
  [[ "$got" == "$want" ]] || { echo "runner guard: elected scale sets '$want' but rendered '$got'" >&2; exit 1; }
  if [[ "$tree" == "aws" ]]; then
    got="$(yq 'select(.kind == "NodePool") | .metadata.name' "$out/rendered-aws-resourceset-nodes.yaml" | grep -v '^---$' | sort | tr '\n' ' ')"
    [[ "$got" == "${want//linux-/github-arc-}" ]] || { echo "runner guard: elected node pools '${want//linux-/github-arc-}' but rendered '$got'" >&2; exit 1; }
  fi
}

run_pass() { # run_pass <tree> <mode>
  local tree="$1" mode="$2" out
  out="$BUILD/$tree-$mode"
  mkdir -p "$out"
  echo ">> [$tree/$mode] building deploy/$tree"
  kustomize build "$ROOT/manifests/deploy/$tree" > "$out/raw.yaml"
  substitute "$out/raw.yaml" "$out/deploy.yaml"
  check_seed_contract "$out/deploy.yaml"
  echo ">> [$tree/$mode] rendering resourcesets with sample inputs"
  render_resourcesets "$tree" "$out"
  check_runners "$tree" "$out"
}

echo ">> null-guard self-test"
null_guard_selftest

for tree in aws google; do
  for mode in keyless keyed; do
    # Each pass runs in a subshell so one cloud's env can never leak into
    # the other's render - absence of the other cloud's vars is part of
    # what is being tested.
    (
      set -a
      # shellcheck disable=SC1090
      source "$ROOT/tests/$tree.env"
      # shellcheck disable=SC1091
      source "$ROOT/tests/github-arc-vars.env"
      if [[ -f "$ROOT/tests/github-arc-vars.$tree.env" ]]; then
        # shellcheck disable=SC1090
        source "$ROOT/tests/github-arc-vars.$tree.env"
      fi
      if [[ "$mode" == "keyed" ]]; then
        # shellcheck disable=SC1090
        source "$ROOT/tests/$tree.keyed.env"
        # the keyed passes double as the other side of the application's
        # gates (single arch, a runner group) - see the fixture's header
        # shellcheck disable=SC1091
        source "$ROOT/tests/github-arc-vars.keyed.env"
      fi
      set +a
      run_pass "$tree" "$mode"
    )
  done
done

echo ">> kubeconform"
# CRD schemas are vendored under tests/schemas (converted from upstream CRDs);
# refresh with: curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
kubeconform -strict -summary \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "$ROOT/tests/schemas/{{ .ResourceKind }}-{{ .Group }}-{{ .ResourceAPIVersion }}.json" \
  "$BUILD"/*/deploy.yaml "$BUILD"/*/rendered-*.yaml

echo ">> validation clean"
