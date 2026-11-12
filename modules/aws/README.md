# modules/aws

Self-hosted GitHub Actions runners on AWS, installed onto a [terraform-aws-eks-flux] cluster as a self-contained
application. The cluster root never learns github-arc exists: this module takes the cluster root's
`application_target` output and installs everything through that repo's [`modules/application`][application] - the
seed (`application-github-arc`), the `github-arc-vars` ConfigMap, the pre-created `github-arc` namespace and the podless
IRSA reader role `<cluster>-secrets-github-arc-github-arc-secrets` the sync KSA assumes. It also creates the three
Secrets Manager secrets the image syncs into the `github-arc-github-app` Secret, under the cluster's `SECRET_PREFIX`
(`create_secrets = false` leaves them to another root; the reader role covers every secret under the prefix either
way).

There is no node group here: each elected architecture's dedicated scale-to-zero capacity is a Karpenter `NodePool`
(`github-arc-amd64`, `github-arc-arm64`) the image ships on the platform's `EC2NodeClass default`, shaped by the
`GITHUB_ARC_<ARCH>_*` vars this module publishes from `runners`.

```hcl
module "github_arc" {
  source = "git::https://github.com/bitwise-media-group/github-arc-app-manifests.git//modules/aws?ref=vX.Y.Z"

  cluster = data.terraform_remote_state.cluster.outputs.application_target
  github  = { config_url = "https://github.com/bitwise-media-group" }
}
```

The root needs an `aws` provider for the cluster's account and region and a `helm` provider pointed at the cluster. The
cluster must elect the platform's `arc` component (`PLATFORM_COMPONENTS`). The secret values are put out of band
(`aws secretsmanager put-secret-value --secret-id <prefix>github-arc-app-id --secret-string ...`, and likewise for
`github-arc-installation-id` and `github-arc-private-key`), so destroying the module with `create_secrets` destroys them
with their secrets. See the repository README for the `github-arc-vars` contract.

[terraform-aws-eks-flux]: https://github.com/bitwise-media-group/terraform-aws-eks-flux
[application]: https://github.com/bitwise-media-group/terraform-aws-eks-flux/tree/main/modules/application

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2 |
| aws | >= 6.0, < 7 |
| helm | >= 3.0, < 4 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| application | git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application | 9fa078f941c9ba8ef97d38eb1fd9ebea01a80999 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_secretsmanager_secret.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to install github-arc onto: pass terraform-aws-eks-flux's application\_target output verbatim (through<br/>terraform\_remote\_state or any other channel). It is handed to that repo's modules/application unchanged, and<br/>supplies the cluster name (IAM role names), the platform registry the image is published beneath<br/>(oci://<platform\_registry>/manifests/github-arc), the SECRET\_PREFIX the secrets are named under and the reader role<br/>is scoped to, the IRSA provider the reader role trusts, and the signing mode (keyless clusters verify the image<br/>against signed\_identity\_subject, KMS-keyed clusters against the cosign-pub Secret). The node facts it also carries<br/>are unused: the runners' capacity is Karpenter NodePools the image ships, on the platform's EC2NodeClass default. | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    oidc_provider_arn = string<br/>    oidc_issuer       = string<br/>    secret_prefix     = string<br/><br/>    node_role_arn             = optional(string)<br/>    node_subnet_ids           = optional(set(string), [])<br/>    cluster_security_group_id = optional(string)<br/><br/>    version               = optional(string)<br/>    endpoint              = optional(string)<br/>    certificate_authority = optional(string)<br/>    service_cidr          = optional(string)<br/>  })</pre> | n/a | yes |
| github | Where the runners register, published as GITHUB\_ARC\_CONFIG\_URL and GITHUB\_ARC\_RUNNER\_GROUP.<br/>  - config\_url: the GitHub org (or enterprise, or repository) URL the scale sets register with, e.g.<br/>    https://github.com/bitwise-media-group. The GitHub App whose credential the image syncs must be installed<br/>    there with the organization permission "Self-hosted runners: read & write".<br/>  - runner\_group: the runner group both scale sets join; null joins the org's Default group. | <pre>object({<br/>    config_url   = string<br/>    runner_group = optional(string)<br/>  })</pre> | n/a | yes |
| create\_secrets | Create the three Secrets Manager secrets (github-arc-app-id, github-arc-installation-id, github-arc-private-key,<br/>under cluster.secret\_prefix). false expects secrets of those names to exist already (another root owns them); the<br/>read grant is identity-side either way - the sync KSA's IRSA reader role covers every secret under<br/>cluster.secret\_prefix - so nothing else changes. | `bool` | `true` | no |
| extra\_vars | Further github-arc-vars keys merged beside the ones this module owns. Keys must be SCREAMING\_SNAKE\_CASE and must not<br/>be one of this module's own keys (GITHUB\_ARC\_*): set those through their own inputs. | `map(string)` | `{}` | no |
| image | Which builds of the manifests image (oci://<cluster.platform\_registry>/manifests/github-arc) the seed follows, passed<br/>straight through to the cluster module's modules/application image (semver and channel only). Terraform owns the<br/>seed on every apply, so this module's version moves the range in the same apply as the infrastructure the<br/>manifests need. The default follows releases below 1.0.0.<br/>  - semver: the tag range; a range matching no tag prunes the application.<br/>  - channel: edge or stable. edge follows the newest <version>-edge.<yyyymmddhhmmss>.g<commit> build, every<br/>    build unless semver bounds it, which then needs a pre-release bound (^0.2.0-0: every edge build up to the<br/>    next breaking change); stable follows the newest vX.Y.Z and takes no semver. | <pre>object({<br/>    semver  = optional(string)<br/>    channel = optional(string)<br/>  })</pre> | <pre>{<br/>  "semver": "<1.0.0 >=0.1.0"<br/>}</pre> | no |
| runners | The runner scale sets, keyed by architecture: amd64 (runs-on: linux-amd64) and arm64 (runs-on: linux-arm64). An<br/>absent key, or enabled = false, elects no scale set and no NodePool for that architecture. Each arch gets a<br/>dedicated scale-to-zero Karpenter NodePool github-arc-<arch> (shipped in the image, on EC2NodeClass default,<br/>tainted platform.bitwisemedia.uk/dedicated=github-arc:NoSchedule) that only its runner pods select; every field<br/>below reaches it as a GITHUB\_ARC\_<ARCH>\_* var.<br/>  - enabled: elect the arch (GITHUB\_ARC\_<ARCH>\_ENABLED).<br/>  - instance\_families: the NodePool's karpenter.k8s.aws/instance-family requirement; null takes m7i,m7a for amd64<br/>    and m7g,m8g for arm64, an empty set drops the requirement (any family of the arch).<br/>  - capacity\_types: karpenter.sh/capacity-type (on-demand, spot, reserved). on-demand by default: a reclaimed<br/>    spot node kills its job.<br/>  - max\_nodes / cpu\_limit / memory\_limit: the NodePool's limits (nodes, cpu, memory).<br/>  - max\_runners: the scale set's ceiling (GITHUB\_ARC\_<ARCH>\_MAX\_RUNNERS); minRunners is always 0.<br/>  - cpu / memory: the runner container's requests (GITHUB\_ARC\_<ARCH>\_CPU / \_MEMORY), sized so one runner fills a<br/>    4 vCPU / 16 GiB instance.<br/>  - consolidate\_after: how long an empty runner node lingers before Karpenter removes it (consolidationPolicy is<br/>    always WhenEmpty, so a running job is never evicted). | <pre>map(object({<br/>    enabled           = optional(bool, true)<br/>    instance_families = optional(set(string))<br/>    capacity_types    = optional(set(string), ["on-demand"])<br/>    max_nodes         = optional(number, 4)<br/>    max_runners       = optional(number, 4)<br/>    cpu               = optional(string, "3")<br/>    memory            = optional(string, "10Gi")<br/>    cpu_limit         = optional(string, "16")<br/>    memory_limit      = optional(string, "64Gi")<br/>    consolidate_after = optional(string, "5m")<br/>  }))</pre> | <pre>{<br/>  "amd64": {},<br/>  "arm64": {}<br/>}</pre> | no |
| signed\_identity\_subject | Fulcio certificate-subject regexp (keyless cosign) of the workflow that signs the manifests image, the seed's<br/>verify subject: this repo's release.yaml on main by default, which signs edge builds and (by promotion) every<br/>release. Ignored on KMS-keyed clusters (cluster.keyed), which verify against the signing key's public half instead. | `string` | `"^https://github.com/bitwise-media-group/github-arc-app-manifests/.github/workflows/release.yaml@refs/heads/main$"` | no |
| tags | Tags applied to every secret and to the secret-sync reader role. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| node\_pools | The Karpenter NodePools the image renders, keyed by elected architecture: the NodePool name and the<br/>platform.bitwisemedia.uk/node-pool label its nodes carry (and the runner pods select). The NodePools themselves are<br/>flux's, not terraform's. |
| release | The seed release (application-github-arc) in the cluster's flux namespace, reconciled by every apply. |
| secret\_reader\_roles | The podless secret-sync reader role ARN, keyed <namespace>/<service\_account>: github-arc/github-arc-secrets. |
| secrets | The GitHub App credential secrets, keyed by unprefixed name: the (prefixed) Secrets Manager name, its ARN (null when<br/>create\_secrets is false - the secret is another root's) and whether this module created it. Every value is put out<br/>of band: aws secretsmanager put-secret-value --secret-id <name>. |
| vars | The github-arc-vars ConfigMap contents: every application-owned key the manifests substitute - the GitHub config<br/>URL and runner group, the per-arch GITHUB\_ARC\_<ARCH>\_* scale-set and Karpenter NodePool settings, the manifests<br/>semver range and signing subject - plus extra\_vars. |
<!-- END_TF_DOCS -->
