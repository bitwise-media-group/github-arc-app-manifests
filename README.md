# github-arc-app-manifests

Self-hosted GitHub Actions runners as an **application image** for the platform clusters. This repo publishes
`oci://<registry>/manifests/github-arc`: a cosign-signed OCI artifact holding two [Actions Runner Controller][arc] scale
sets, `linux-amd64` and `linux-arm64`, with Docker-in-Docker on dedicated scale-to-zero capacity, plus the per-cloud
terraform modules that install it onto a cluster. The modules seed the image and pick which builds it follows on every
apply; everything outside the cluster (the GitHub App's secret containers and grants, the `github-arc-vars` ConfigMap,
the GKE runner node pools) goes through the cluster modules' generic `modules/application` and `modules/node-pool`. The
cluster module itself has no knowledge of github-arc.

The application is named `github-arc` because `arc` is the platform component that runs the ARC controller
(`arc-systems/arc-gha-rs-controller`). This image ships only the scale sets, and depends on that component.

| Repo                                                   | Role                                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| **github-arc-app-manifests** (this)                    | the runner scale sets image, and the terraform modules that install it               |
| [flux-manifests]                                       | the platform: the `arc` controller component, Karpenter, secret sync, Kyverno        |
| [flux-containers]                                      | the mirror: the `gha-runner-scale-set` chart and the runner and `docker:dind` images |
| [terraform-google-gke-flux] / [terraform-aws-eks-flux] | the clusters, `modules/application`, `modules/node-pool`                             |

## Using the runners

```yaml
jobs:
  build:
    runs-on: linux-arm64 # or linux-amd64
    steps:
      - uses: actions/checkout@v4
      - run: docker build .
```

Each job gets a fresh ephemeral pod (the `actions-runner` image plus a privileged `dockerd` sidecar) on a node dedicated
to github-arc. Both scale sets run `minRunners: 0` on capacity that starts at zero nodes, so an idle cluster runs no
runners; the first job after an idle spell waits a minute or two for a node.

## Installing

1. **Create a GitHub App** on the `bitwise-media-group` org with the organization permission **Self-hosted runners: Read
   and write** (no webhook), generate a private key, install it on the org, and note the App ID and installation ID.
2. **Apply the module** for the cluster's cloud:

   ```hcl
   module "github_arc" {
     source = "git::https://github.com/bitwise-media-group/github-arc-app-manifests.git//modules/google?ref=vX.Y.Z"

     cluster = data.terraform_remote_state.cluster.outputs.application_target
     github  = { config_url = "https://github.com/bitwise-media-group" }
   }
   ```

   `modules/aws` takes the same inputs. The cluster must elect `arc` in `PLATFORM_COMPONENTS`.

3. **Load the credential** into the three containers, named under the cluster's `SECRET_PREFIX`:

   ```sh
   printf '%s' "<app-id>" | gcloud secrets versions add "${PREFIX}github-arc-app-id" --data-file=-
   printf '%s' "<installation-id>" | gcloud secrets versions add "${PREFIX}github-arc-installation-id" --data-file=-
   gcloud secrets versions add "${PREFIX}github-arc-private-key" --data-file=the-app.private-key.pem
   ```

   On aws: `aws secretsmanager put-secret-value --secret-id "${PREFIX}github-arc-app-id" --secret-string ...`, and
   likewise for the other two.

The full walk-through is [Installing github-arc][installing] on the documentation site.

## What the image deploys

- **No seed objects.** The modules' seed (the RSIP and ResourceSet `github-arc-manifests`, kept by terraform on every
  apply) emits `OCIRepository` and `Kustomization github-arc` (path `./${PLATFORM_TREE}`, substituting from
  `cluster-vars` and `github-arc-vars`, depending on `kyverno-policies` and `arc`, plus `secret-sync` and `karpenter` on
  aws); the image ships no copy.
- **The core** (`common/`): the `github-arc` namespace (Pod Security `privileged`), the mirrored `gha-runner-scale-set`
  chart on the platform's `ARC_SEMVER` range, and one `HelmRelease linux-<arch>` per elected architecture, gated inline
  by `GITHUB_ARC_<ARCH>_ENABLED`. The dind pod is spelled out with `containerMode` unset, because the chart hardcodes
  `docker:dind` from Docker Hub, which the platform signature policy rejects.
- **The overlays** (`google/`, `aws/`): the GitHub App sync into `Secret/github-arc-github-app` in the cloud's dialect,
  and each scale set's scheduling - the `github-arc-<arch>` GKE node pool on google (plus GKE's Arm taint on arm64), a
  Karpenter `NodePool github-arc-<arch>` on `EC2NodeClass default` on aws.

## `github-arc-vars`

| Key                                                                                                             | Source (module input)            |
| --------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `GITHUB_ARC_CONFIG_URL`                                                                                         | `github.config_url`              |
| `GITHUB_ARC_RUNNER_GROUP`                                                                                       | `github.runner_group`            |
| `GITHUB_ARC_<ARCH>_ENABLED`                                                                                     | `runners.<arch>.enabled`         |
| `GITHUB_ARC_<ARCH>_MAX_RUNNERS`                                                                                 | `runners.<arch>.max_runners`     |
| `GITHUB_ARC_<ARCH>_CPU` / `_MEMORY`                                                                             | `runners.<arch>.cpu` / `.memory` |
| `GITHUB_ARC_<ARCH>_{INSTANCE_FAMILIES,CAPACITY_TYPES,CPU_LIMIT,MEMORY_LIMIT,MAX_NODES,CONSOLIDATE_AFTER}` (aws) | `runners.<arch>.*`               |

The modules publish every key for both architectures, elected or not; the manifests read them bare. See [Variables &
inputs][variables].

## Releases

Every push to main that cuts no release publishes `manifests/` as an immutable
`manifests/github-arc:<next version>-edge.<timestamp>.g<commit>` build; merging the release PR cuts `vX.Y.Z` and adds
that tag to the newest edge build of the version, without rebuilding. Both run in `release.yaml`'s publish job
(github-workflows' `patchy-publish` action), signed keylessly as this repository's release workflow on `main`. Clusters
follow **releases** through the modules' `image.semver` by default; `image.channel = "edge"` follows the edge builds
instead (bounded with a pre-release range such as `image.semver = "^0.2.0-0"`).

## Developing

```sh
make test   # render + substitute + kubeconform every tree, then terraform test both modules
make lint   # license headers, prose, shell, workflows, kubescape
make serve  # the documentation site on localhost:8006
```

The documentation site is at <https://oss.bitwisemedia.uk/github-arc-app-manifests/>.

[arc]: https://github.com/actions/actions-runner-controller
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests
[flux-containers]: https://github.com/bitwise-media-group/flux-containers
[terraform-google-gke-flux]: https://github.com/bitwise-media-group/terraform-google-gke-flux
[terraform-aws-eks-flux]: https://github.com/bitwise-media-group/terraform-aws-eks-flux
[installing]: https://oss.bitwisemedia.uk/github-arc-app-manifests/getting-started/installing/
[variables]: https://oss.bitwisemedia.uk/github-arc-app-manifests/reference/variables/
