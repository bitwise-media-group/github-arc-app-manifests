# modules/google

Self-hosted GitHub Actions runners on Google Cloud, installed onto a [terraform-google-gke-flux] cluster as a
self-contained application. The cluster root never learns github-arc exists: this module takes the cluster root's
`application_target` output and installs everything through that repo's [`modules/application`][application] - the
seed (`application-github-arc`), the `github-arc-vars` ConfigMap and the pre-created `github-arc` namespace. Beside it,
it creates one dedicated scale-to-zero GKE node pool per elected architecture through [`modules/node-pool`][node-pool]
(`github-arc-amd64` on `e2-standard-4`, `github-arc-arm64` on `t2a-standard-4`, both tainted
`platform.bitwisemedia.uk/dedicated=github-arc:NoSchedule`), and the three Secret Manager containers the image syncs
into the `github-arc-github-app` Secret, each with a `secretAccessor` grant for the federated principal of the sync KSA
(`ns/github-arc/sa/github-arc-secrets`). With `create_secrets = false` it grants on existing containers of the same
names instead.

```hcl
module "github_arc" {
  source = "git::https://github.com/bitwise-media-group/github-arc-app-manifests.git//modules/google?ref=vX.Y.Z"

  cluster = data.terraform_remote_state.cluster.outputs.application_target
  github  = { config_url = "https://github.com/bitwise-media-group" }

  # optional: both architectures are elected by default
  runners = {
    amd64 = {}
    arm64 = { node_locations = ["us-central1-a"] } # T2A zones
  }
}
```

The root needs a `google` provider for the cluster's project and a `helm` provider pointed at the cluster. The cluster
must elect the platform's `arc` component (`PLATFORM_COMPONENTS`). The container versions are added out of band
(`gcloud secrets versions add <prefix>github-arc-app-id --data-file=-`, and likewise for
`github-arc-installation-id` and `github-arc-private-key`), so destroying the module with `create_secrets` destroys them
with their containers. See the repository README for the `github-arc-vars` contract.

[terraform-google-gke-flux]: https://github.com/bitwise-media-group/terraform-google-gke-flux
[application]: https://github.com/bitwise-media-group/terraform-google-gke-flux/tree/main/modules/application
[node-pool]: https://github.com/bitwise-media-group/terraform-google-gke-flux/tree/main/modules/node-pool

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46, < 8.10 |
| helm | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.46, < 8.10 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| application | git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/application | d74b5323d24b795a644a184a57aa85ea109e3de2 |
| node\_pool | git::https://github.com/bitwise-media-group/terraform-google-gke-flux.git//modules/node-pool | d74b5323d24b795a644a184a57aa85ea109e3de2 |

## Resources

| Name | Type |
| ---- | ---- |
| [google_secret_manager_secret.main](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.sync](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to install github-arc onto: pass terraform-google-gke-flux's application\_target output verbatim<br/>(through terraform\_remote\_state or any other channel). It is handed to that repo's modules/application<br/>unchanged, and supplies the project the containers and node pools live in, the platform registry the image is<br/>published beneath (oci://<platform\_registry>/manifests/github-arc), the SECRET\_PREFIX the containers are named<br/>under, the project number and Workload Identity pool the sync KSA's federated principal is composed from, the<br/>signing mode (keyless clusters verify the image against signed\_identity\_subject, KMS-keyed clusters against the<br/>cosign-pub Secret), and the node facts every runner node pool is built from (location, node\_locations,<br/>node\_service\_account). | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    project           = string<br/>    project_number    = string<br/>    workload_pool     = string<br/>    secret_prefix     = string<br/><br/>    location             = string<br/>    node_locations       = optional(set(string), [])<br/>    node_service_account = string<br/>  })</pre> | n/a | yes |
| github | Where the runners register, published as GITHUB\_ARC\_CONFIG\_URL and GITHUB\_ARC\_RUNNER\_GROUP.<br/>  - config\_url: the GitHub org (or enterprise, or repository) URL the scale sets register with, e.g.<br/>    https://github.com/bitwise-media-group. The GitHub App whose credential the image syncs must be installed<br/>    there with the organization permission "Self-hosted runners: read & write".<br/>  - runner\_group: the runner group both scale sets join; null joins the org's Default group. | <pre>object({<br/>    config_url   = string<br/>    runner_group = optional(string)<br/>  })</pre> | n/a | yes |
| create\_secrets | Create the three Secret Manager containers (github-arc-app-id, github-arc-installation-id, github-arc-private-key,<br/>under cluster.secret\_prefix in cluster.project). false grants the sync KSA accessor on containers of those names<br/>that already exist (another root owns them) instead of creating them - the grants are resource-side, so they<br/>still need the names. | `bool` | `true` | no |
| extra\_vars | Further github-arc-vars keys merged beside the ones this module owns. Keys must be SCREAMING\_SNAKE\_CASE and must not<br/>be one of this module's own keys (GITHUB\_ARC\_*, SIGNED\_IDENTITY\_GITHUB\_ARC\_MANIFESTS): set those through their own<br/>inputs. | `map(string)` | `{}` | no |
| labels | Labels applied to every secret container and, as GCP resource labels, to every runner node. | `map(string)` | `{}` | no |
| manifests\_semver | The semver range the seed follows for the manifests image (GITHUB\_ARC\_MANIFESTS\_SEMVER); a range matching no tag prunes the application. | `string` | `"<1.0.0 >=0.1.0"` | no |
| runners | The runner scale sets, keyed by architecture: amd64 (runs-on: linux-amd64) and arm64 (runs-on: linux-arm64). An<br/>absent key, or enabled = false, elects no scale set and no node pool for that architecture. Each arch gets a<br/>dedicated scale-to-zero GKE node pool github-arc-<arch> (min 0, tainted platform.bitwisemedia.uk/dedicated=<br/>github-arc:NoSchedule) that only its runner pods select.<br/>  - enabled: elect the arch (GITHUB\_ARC\_<ARCH>\_ENABLED).<br/>  - machine\_type: the pool's machine type; e2-standard-4 for amd64, t2a-standard-4 for arm64 (T2A is pd-backed and<br/>    offered in fewer zones than E2 - see node\_locations; C4A would need hyperdisk).<br/>  - spot: run the pool on Spot VMs (location policy ANY). Off by default: a preempted node kills its job.<br/>  - max\_nodes: the pool's ceiling, a cluster-wide total.<br/>  - max\_runners: the scale set's ceiling (GITHUB\_ARC\_<ARCH>\_MAX\_RUNNERS); minRunners is always 0.<br/>  - disk\_size\_gib: each node's boot disk, which holds every image a dind job pulls or builds.<br/>  - cpu / memory: the runner container's requests (GITHUB\_ARC\_<ARCH>\_CPU / \_MEMORY). The defaults fill one 4 vCPU /<br/>    16 GiB node, so exactly one runner lands per node and max\_nodes = max\_runners.<br/>  - node\_locations: zones for this pool only; null takes cluster.node\_locations (empty inherits the cluster's). | <pre>map(object({<br/>    enabled        = optional(bool, true)<br/>    machine_type   = optional(string)<br/>    spot           = optional(bool, false)<br/>    max_nodes      = optional(number, 4)<br/>    max_runners    = optional(number, 4)<br/>    disk_size_gib  = optional(number, 100)<br/>    cpu            = optional(string, "3")<br/>    memory         = optional(string, "10Gi")<br/>    node_locations = optional(set(string))<br/>  }))</pre> | <pre>{<br/>  "amd64": {},<br/>  "arm64": {}<br/>}</pre> | no |
| signed\_identity\_subject | Fulcio certificate-subject regexp of the workflow that signs the manifests image<br/>(SIGNED\_IDENTITY\_GITHUB\_ARC\_MANIFESTS, and the seed's verify subject); this repo's release.yaml on main by default,<br/>which signs edge builds and (by promotion) every release. Ignored on KMS-keyed clusters (cluster.keyed), which verify against the signing key's public half instead. | `string` | `"^https://github.com/bitwise-media-group/github-arc-app-manifests/.github/workflows/release.yaml@refs/heads/main$"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| node\_pools | The dedicated runner node pools, keyed by elected architecture: the pool name (the<br/>cloud.google.com/gke-nodepool value the runner pods select), its id and its Kubernetes labels. |
| release | The bootstrap-only seed release (application-github-arc) in the cluster's flux namespace. |
| secrets | The GitHub App credential containers, keyed by unprefixed name: the resource id, the (prefixed) secret id and<br/>whether this module created it (create\_secrets). Versions are added out of band: gcloud secrets versions add <id><br/>--data-file=-. |
| vars | The github-arc-vars ConfigMap contents: every application-owned key the manifests substitute - the GitHub config<br/>URL and runner group, the per-arch GITHUB\_ARC\_<ARCH>\_{ENABLED,MAX\_RUNNERS,CPU,MEMORY}, the manifests semver range<br/>and signing subject - plus extra\_vars. |
<!-- END_TF_DOCS -->
