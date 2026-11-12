# Installing github-arc

Four steps: create a GitHub App, apply the module, load the App's credential, and point workflows at the new labels. The
cluster must already run the platform's [arc component](https://oss.bitwisemedia.uk/flux-manifests/components/arc/)
(`arc` in `PLATFORM_COMPONENTS`); the image's Kustomization waits on it.

## 1. Create the GitHub App

The scale sets register with GitHub as a GitHub App installed on the org. In the `bitwise-media-group` org, open
**Settings → Developer settings → GitHub Apps → New GitHub App**:

- **Name**: anything unique, e.g. `bitwise-media-group-arc-<cluster>`. **Homepage URL**: the org or this repository.
- **Webhook**: clear **Active**. ARC's listener polls GitHub; it needs no webhook.
- **Permissions → Organization permissions → Self-hosted runners: Read and write.** That's the only one ARC needs for
  org-level runners (Metadata: read-only is added by GitHub on its own).
- **Where can this GitHub App be installed?** Only on this account.

Create it, then on the App's settings page:

1. Note the **App ID** (in the **About** section).
2. Under **Private keys**, **Generate a private key**. The browser downloads a `.pem` file: that's the credential, so
   keep it out of anything that isn't the secret store.

Then **Install App** on `bitwise-media-group` (all repositories, or only the ones that may use the runners). The
installation's URL ends in its **installation ID**:
`https://github.com/organizations/bitwise-media-group/settings/installations/<installation-id>`.

!!! tip "Runner groups"

    Both scale sets join the org's **Default** runner group unless `github.runner_group` names another. To restrict
    which repositories can use the runners, create a group under **Settings → Actions → Runner groups** first, and pass
    its name.

!!! warning "Public repositories"

    A job on these runners has a privileged Docker daemon beside it, so it is effectively root on its node. Don't
    expose the runners to public repositories, whose pull requests run untrusted code; GitHub disables self-hosted
    runners for public repositories in the Default group unless you allow it.

## 2. Apply the module

From any root that can read the cluster root's `application_target` output (the cluster root itself, or a root of its
own):

=== "google"

    ```hcl
    data "terraform_remote_state" "cluster" {
      backend = "gcs"
      config  = { bucket = "...", prefix = "clusters/ci-test" }
    }

    module "github_arc" {
      source = "git::https://github.com/bitwise-media-group/github-arc-app-manifests.git//modules/google?ref=vX.Y.Z"

      cluster = data.terraform_remote_state.cluster.outputs.application_target
      github  = { config_url = "https://github.com/bitwise-media-group" }

      # optional - both architectures at the defaults is the same as omitting it
      runners = {
        amd64 = {}
        arm64 = { node_locations = ["us-central1-a"] } # pin T2A to zones that offer it
      }
    }
    ```

    The root needs a `google` provider for the cluster's project and a `helm` provider pointed at the cluster. The
    module creates the `github-arc-amd64` and `github-arc-arm64` node pools (min 0), the three Secret Manager
    containers with their accessor grants, and the seed.

=== "aws"

    ```hcl
    module "github_arc" {
      source = "git::https://github.com/bitwise-media-group/github-arc-app-manifests.git//modules/aws?ref=vX.Y.Z"

      cluster = data.terraform_remote_state.cluster.outputs.application_target
      github  = { config_url = "https://github.com/bitwise-media-group" }
    }
    ```

    The root needs an `aws` provider for the cluster's account and region and a `helm` provider pointed at the
    cluster. The module creates the three Secrets Manager secrets, the sync KSA's IRSA reader role and the seed; the
    Karpenter NodePools ship in the image.

Already have the containers from another root? Pass `create_secrets = false`: the module then grants on (google) or
expects (aws) containers of the same names instead of creating them.

## 3. Load the credential

The module creates the containers; their values never pass through terraform. Each name carries the cluster's
`SECRET_PREFIX` (the cluster root's `secret_prefix` output; empty when the cluster has none):

=== "google"

    ```sh
    PREFIX=ci-test-          # the cluster's SECRET_PREFIX
    PROJECT=ci-test-project  # the cluster's project

    printf '%s' "<app-id>" \
      | gcloud secrets versions add "${PREFIX}github-arc-app-id" --project "$PROJECT" --data-file=-
    printf '%s' "<installation-id>" \
      | gcloud secrets versions add "${PREFIX}github-arc-installation-id" --project "$PROJECT" --data-file=-
    gcloud secrets versions add "${PREFIX}github-arc-private-key" --project "$PROJECT" \
      --data-file=path/to/the-app.private-key.pem
    ```

=== "aws"

    ```sh
    PREFIX=ci-test-  # the cluster's SECRET_PREFIX

    aws secretsmanager put-secret-value --secret-id "${PREFIX}github-arc-app-id" --secret-string "<app-id>"
    aws secretsmanager put-secret-value --secret-id "${PREFIX}github-arc-installation-id" \
      --secret-string "<installation-id>"
    aws secretsmanager put-secret-value --secret-id "${PREFIX}github-arc-private-key" \
      --secret-string file://path/to/the-app.private-key.pem
    ```

The image syncs all three into the `github-arc/github-arc-github-app` Secret, under the keys ARC reads (`github_app_id`,
`github_app_installation_id`, `github_app_private_key`). Until they exist the sync errors and the scale sets' listeners
can't authenticate; flux retries, so loading them after the apply is fine. To rotate the key, add a new version and
delete the old key on the App.

## 4. Check it's running

```sh
flux get kustomizations github-arc
kubectl -n github-arc get helmreleases,autoscalingrunnersets
kubectl -n arc-systems get pods   # one listener per scale set
```

In the org's **Settings → Actions → Runners**, both scale sets appear as `linux-amd64` and `linux-arm64`, with no
runners while idle.

## Using the runners

Target a scale set by its name:

```yaml
jobs:
  test:
    runs-on: linux-amd64
  build-arm:
    runs-on: linux-arm64
```

Each job gets a fresh ephemeral pod: the runner container plus a privileged `dockerd` sidecar (`DOCKER_HOST` points at
its socket), on a node dedicated to github-arc. The runner image is this repository's `Dockerfile.runner`:
`actions/actions-runner` with mise and every tool the shared toolchain pins already installed where `jdx/mise-action`
looks, so a mise-based job installs nothing. It is not GitHub's hosted `ubuntu-latest` image, so install anything else a
job needs (or run the job in a `container:`).

### Scale to zero

Both scale sets run `minRunners: 0`, and their capacity scales the same way:

1. **Idle.** No runner pods, no runner nodes. Only the listeners (in `arc-systems`, on the system nodes) run, polling
   GitHub for jobs.
2. **A job is queued.** The listener asks the controller for a runner; the runner pod is unschedulable until a node
   arrives. On google the cluster autoscaler grows the `github-arc-<arch>` pool; on aws Karpenter launches a node for
   the `github-arc-<arch>` NodePool. The first job after an idle spell waits for that node, typically one to three
   minutes; later jobs reuse warm nodes while they last.
3. **The job ends.** The runner pod is deleted. Once a node is empty it is removed: after the cluster autoscaler's
   scale-down delay (about ten minutes) on google, after `consolidate_after` (default `5m`) on aws. A node running a job
   is never consolidated away (`WhenEmpty`).

`max_runners` caps concurrent jobs per architecture and `max_nodes` caps the capacity behind them. The default requests
(`cpu = "3"`, `memory = "10Gi"`) fill one 4 vCPU / 16 GiB node, so each job gets a node to itself.
