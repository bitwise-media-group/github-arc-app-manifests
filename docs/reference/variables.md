# Variables & inputs

The image substitutes two ConfigMaps (`postBuild.substituteFrom`): the platform's `cluster-vars` and the application's
own `github-arc-vars`, which `modules/aws` or `modules/google` publish (their `vars` output) from the inputs below.
Every `GITHUB_ARC_*` key is read **bare**: the modules always publish all of them, for both architectures, elected or
not, and `make test` substitutes strictly, so a manifest reaching for a key the modules don't publish fails the build.

## `github-arc-vars`

| Key                                    | Module input                 | Default                                 | Read by                           |
| -------------------------------------- | ---------------------------- | --------------------------------------- | --------------------------------- |
| `GITHUB_ARC_CONFIG_URL`                | `github.config_url`          | (required)                              | both scale sets                   |
| `GITHUB_ARC_RUNNER_GROUP`              | `github.runner_group`        | `""` (the Default group)                | both scale sets, when non-empty   |
| `GITHUB_ARC_<ARCH>_ENABLED`            | `runners.<arch>.enabled`     | `"true"` (`"false"` for an absent key)  | the arch's scale set (+ NodePool) |
| `GITHUB_ARC_<ARCH>_MAX_RUNNERS`        | `runners.<arch>.max_runners` | `4`                                     | `maxRunners`                      |
| `GITHUB_ARC_<ARCH>_CPU`                | `runners.<arch>.cpu`         | `3`                                     | the runner's CPU request          |
| `GITHUB_ARC_<ARCH>_MEMORY`             | `runners.<arch>.memory`      | `10Gi`                                  | the runner's memory request       |
| `GITHUB_ARC_MANIFESTS_SEMVER`          | `manifests_semver`           | `<1.0.0 >=0.1.0`                        | the image's own input provider    |
| `SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS` | `signed_identity_subject`    | this repo's `publish.yaml@refs/tags/v*` | the image's own verify block      |

aws only (`modules/aws`), read by `deploy/aws/resourceset-nodes.yaml`:

| Key                                   | Module input                       | Default               | NodePool field                                       |
| ------------------------------------- | ---------------------------------- | --------------------- | ---------------------------------------------------- |
| `GITHUB_ARC_<ARCH>_INSTANCE_FAMILIES` | `runners.<arch>.instance_families` | `m7i,m7a` / `m7g,m8g` | `karpenter.k8s.aws/instance-family` (empty drops it) |
| `GITHUB_ARC_<ARCH>_CAPACITY_TYPES`    | `runners.<arch>.capacity_types`    | `on-demand`           | `karpenter.sh/capacity-type`                         |
| `GITHUB_ARC_<ARCH>_CPU_LIMIT`         | `runners.<arch>.cpu_limit`         | `16`                  | `limits.cpu`                                         |
| `GITHUB_ARC_<ARCH>_MEMORY_LIMIT`      | `runners.<arch>.memory_limit`      | `64Gi`                | `limits.memory`                                      |
| `GITHUB_ARC_<ARCH>_MAX_NODES`         | `runners.<arch>.max_nodes`         | `4`                   | `limits.nodes`                                       |
| `GITHUB_ARC_<ARCH>_CONSOLIDATE_AFTER` | `runners.<arch>.consolidate_after` | `5m`                  | `disruption.consolidateAfter`                        |

`<ARCH>` is `AMD64` or `ARM64`. Caller extras ride `extra_vars`; they may not shadow a `GITHUB_ARC_*` key or
`SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS`.

## Platform variables the image reads

From `cluster-vars`: `PLATFORM_REGISTRY` (the chart and the image), `CONTAINER_REGISTRY` (the runner and `docker:dind`
images), `PLATFORM_TREE`, `SECRET_PREFIX`, `GCP_PROJECT` (google) or `AWS_REGION` and `SECRETS_ROLE_PREFIX` (aws),
`OCI_PROVIDER` and `ARTIFACT_TAG_PROVIDER`, and the signing set (`SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_CHARTS`,
`SIGNED_IDENTITY_KMS_KEY`, `COSIGN_PUBLIC_KEY`). `ARC_SEMVER` is optional: the scale-set chart follows it with the arc
component's own default, `<1.0.0 >=0.14.0`, so the scale sets always track the controller's range.

## `modules/google` inputs

| Input                     | Type                                                               | Default                      |
| ------------------------- | ------------------------------------------------------------------ | ---------------------------- |
| `cluster`                 | gke-flux `application_target`                                      | (required)                   |
| `github`                  | `object({ config_url = string, runner_group = optional(string) })` | (required)                   |
| `runners`                 | `map(object)` keyed `amd64` / `arm64`                              | `{ amd64 = {}, arm64 = {} }` |
| `create_secrets`          | `bool`                                                             | `true`                       |
| `manifests_semver`        | `string`                                                           | `<1.0.0 >=0.1.0`             |
| `signed_identity_subject` | `string`                                                           | this repo's publish identity |
| `extra_vars`              | `map(string)`                                                      | `{}`                         |
| `labels`                  | `map(string)`                                                      | `{}`                         |

Each `runners` entry: `enabled` (`true`), `machine_type` (`e2-standard-4` / `t2a-standard-4`), `spot` (`false`),
`max_nodes` (`4`), `max_runners` (`4`), `disk_size_gib` (`100`), `cpu` (`"3"`), `memory` (`"10Gi"`) and `node_locations`
(`null`: the cluster's). The `cluster` object must carry the node facts `location` and `node_service_account`
(`node_locations` is optional), which a terraform-google-gke-flux `application_target` does.

## `modules/aws` inputs

The same as google but for the capacity and the tagging: `tags` in place of `labels`, and each `runners` entry has
`enabled`, `instance_families`, `capacity_types`, `max_nodes`, `max_runners`, `cpu`, `memory`, `cpu_limit`,
`memory_limit` and `consolidate_after` - no machine type, spot flag or disk, which are Karpenter's and the
`EC2NodeClass default`'s.

The full tables, with every description, are on the [aws](modules/aws.md) and [google](modules/google.md) module pages.
