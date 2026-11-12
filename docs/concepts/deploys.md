# What the image deploys

`kustomize build manifests/<tree>` is everything a cluster applies: the cloud-neutral core in `common` and the per-cloud
overlay.

| Object                                                        | Where             | What it is                                                         |
| ------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------ |
| `Namespace/github-arc`                                        | common            | Pod Security `privileged` (enforce, audit, warn)                   |
| `ResourceSetInputProvider/github-arc`                         | common            | the mirrored `gha-runner-scale-set` chart's tags, on `ARC_SEMVER`  |
| `ResourceSet/github-arc`                                      | common            | the chart's `OCIRepository` and one `HelmRelease` per elected arch |
| `HelmRelease/linux-amd64`, `HelmRelease/linux-arm64`          | common (rendered) | the scale sets; the name is the `runs-on` label                    |
| `ServiceAccount/github-arc-secrets`                           | overlay           | the identity the secret sync runs as                               |
| `SecretProviderClass` + `SecretSync` `github-arc-github-app`  | overlay           | the GitHub App credential, in the cloud's dialect                  |
| `ConfigMap/github-arc-linux-<arch>-scheduling`                | overlay           | each scale set's `nodeSelector` and tolerations                    |
| `ResourceSet/github-arc-nodes` → `NodePool/github-arc-<arch>` | aws               | the runners' dedicated Karpenter capacity                          |

## The scale sets

Each `HelmRelease` installs the mirrored chart with:

- `githubConfigUrl: ${GITHUB_ARC_CONFIG_URL}` and `githubConfigSecret: github-arc-github-app`, the synced App
  credential;
- `runnerScaleSetName: linux-<arch>` and, when `GITHUB_ARC_RUNNER_GROUP` is non-empty, `runnerGroup`;
- `minRunners: 0` and `maxRunners: ${GITHUB_ARC_<ARCH>_MAX_RUNNERS}`;
- `controllerServiceAccount: {namespace: arc-systems, name: arc-gha-rs-controller}`, the platform arc component's
  controller;
- runner requests `${GITHUB_ARC_<ARCH>_CPU}` / `${GITHUB_ARC_<ARCH>_MEMORY}`, and no limits: a CPU limit only throttles
  a build, a memory limit OOM-kills it.

The chart source is the platform's: `oci://${PLATFORM_REGISTRY}/charts/gha-runner-scale-set`, cosign-verified against
the flux-containers chart identity (or the `cosign-pub` key on KMS-keyed clusters), on the platform's `ARC_SEMVER` range
with the arc component's own default. The controller and scale-set charts release in lockstep, so a scale set always
tracks the controller's range.

### The architecture gate

`GITHUB_ARC_AMD64_ENABLED` and `GITHUB_ARC_ARM64_ENABLED` gate each scale set (and, on aws, its NodePool). kustomize
can't emit a resource conditionally and flux's post-build substitution only fills scalars, so the releases ride a
`ResourceSet` template that compares each var inline: a disabled arch renders no `HelmRelease` at all, and turning one
off later garbage-collects it. The vars are read in the template text rather than through `spec.inputs`, because
substitution round-trips `spec.inputs` through YAML, turning `"true"` into a bool and an empty value into null.

## Docker-in-Docker, on mirrored images

Every runner pod carries a `dockerd` sidecar so jobs can build and run containers. The chart's
`containerMode.type: dind` would render that sidecar from a helper that hardcodes `image: docker:dind`, which no value
overrides, and the platform's `verify-platform-signature` policy rejects anything that isn't from the mirror.

The image leaves `containerMode` unset and spells the dind pod out in `template.spec`, the expanded form ARC documents
for customising dind:

- an `init-dind-externals` init container (the runner image) copying the runner's externals to a shared volume;
- the `dind` sidecar, a native sidecar (`restartPolicy: Always` on an init container), running
  `${CONTAINER_REGISTRY}/images/docker.io/library/docker:dind` privileged, with a `docker info` startup probe;
- the `runner` container, `${CONTAINER_REGISTRY}/images/ghcr.io/actions/actions-runner:2.338.0`, with
  `DOCKER_HOST=unix:///var/run/docker.sock`;
- `work`, `dind-sock` and `dind-externals` emptyDir volumes.

The alternative, a `postRenderers` patch on the rendered `AutoscalingRunnerSet`, is the more fragile one. The
`AutoscalingRunnerSet` is a CRD, so kustomize can't strategic-merge its containers by name (without a schema, lists are
replaced wholesale), and a JSON patch has to address the sidecar by index - an index the chart picks, and moves between
`initContainers` and `containers` depending on the cluster's Kubernetes version. Spelled out, every image is a value
this repository owns, and `make test` asserts each one sits under the platform mirror.

Images are referenced by tag, the platform convention. The mirror locks `docker:dind` to a digest (`sha256:d035bd30…`)
in its `images.lock.yaml` and serves that digest under the `dind` tag, re-locked only through a reviewed mirror change;
Kyverno verifies the mirror's signature on whatever the tag resolves to.

### Privilege

`dockerd` needs `privileged: true`, so the `github-arc` namespace is labelled Pod Security `privileged`. No platform
Kyverno policy blocks privileged pods (the platform enforces `verify-platform-signature` alone, which the mirrored
images pass), so the image ships no `PolicyException`; none may ever except the runners from the signature rule. The
privilege is contained by placement: the runner pods run only on dedicated, tainted capacity nothing else tolerates.

## Scheduling, per cloud

The common `HelmRelease`s don't know which nodes they land on. Each reads its pod scheduling from the overlay's
`github-arc-linux-<arch>-scheduling` ConfigMap through `valuesFrom`, merged under its own values:

=== "google"

    - `nodeSelector: {cloud.google.com/gke-nodepool: github-arc-<arch>}`, the pool `modules/google` creates (selecting
      the pool by name also stops node auto-provisioning creating a look-alike when it's at its maximum);
    - a toleration for `platform.bitwisemedia.uk/dedicated=github-arc:NoSchedule`, the pool's taint;
    - on arm64, a toleration for `kubernetes.io/arch=arm64:NoSchedule`, the taint GKE puts on every Arm node.

=== "aws"

    - `nodeSelector: {platform.bitwisemedia.uk/node-pool: github-arc-<arch>}`, the label the NodePool stamps;
    - a toleration for `platform.bitwisemedia.uk/dedicated=github-arc:NoSchedule`, the NodePool's taint.

    Each `NodePool github-arc-<arch>` references the platform's shared `EC2NodeClass default`, repeats the Cilium
    bootstrap taint (`node.cilium.io/agent-not-ready=true:NoExecute`) as a startup taint, requires its arch, the
    `GITHUB_ARC_<ARCH>_CAPACITY_TYPES` and (when non-empty) the `GITHUB_ARC_<ARCH>_INSTANCE_FAMILIES`, carries
    `limits` from `_CPU_LIMIT`, `_MEMORY_LIMIT` and `_MAX_NODES`, and consolidates `WhenEmpty` after
    `_CONSOLIDATE_AFTER`, so a running job is never evicted.

## The GitHub App credential

Each overlay syncs three secret containers into `Secret/github-arc-github-app`:

| Container (under `SECRET_PREFIX`) | Secret key                   |
| --------------------------------- | ---------------------------- |
| `github-arc-app-id`               | `github_app_id`              |
| `github-arc-installation-id`      | `github_app_installation_id` |
| `github-arc-private-key`          | `github_app_private_key`     |

On google the sync runs as `github-arc-secrets`, whose federated principal `modules/google` grants `secretAccessor` on
each container. On aws it runs as the same KSA, annotated with
`eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}github-arc-github-arc-secrets`, the IRSA reader role `modules/aws`
mints through `secret_readers`.
