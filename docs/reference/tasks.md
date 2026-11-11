# Tasks & validation

Every verb is a [mise](https://mise.jdx.dev) task. The shared [toolchain](https://oss.bitwisemedia.uk/toolchain/),
mounted at `.mise/`, provides the pinned tools, the common lint contract and the docs-site tasks, the containers
archetype adds the image build, and the repository's `tasks.toml` carries the validation surface. The `Makefile` only
forwards: `make <task>` is `mise run <task>`.

| Task                  | What it does                                                                                        |
| --------------------- | --------------------------------------------------------------------------------------------------- |
| `make test`           | `test-manifests`, then `test-modules`                                                               |
| `make test-manifests` | the render + schema harness, `scripts/validate.sh`                                                  |
| `make test-modules`   | `terraform init` + `validate` + `test` (mocked providers) in each module                            |
| `make lint`           | license headers, prose, shell, actionlint + zizmor, and kubescape over the per-cloud trees          |
| `make fmt`            | prose format, `terraform fmt`, license headers                                                      |
| `make build`          | `patchy build --all --dry-run`: packages the manifests image (`patchy.yaml`), publishes nothing     |
| `make docs-build`     | `zensical build` of this site into `site/`                                                          |
| `make serve`          | this site on <http://localhost:8006>, with live reload                                              |
| `make ci`             | `lint`, `test`, `build` and `docs-build`: what the reusable CI workflow runs                        |
| `make pr`             | `fmt`, `lint`, `test`, `build` and `docs-build`, then `./commit.sh` if present: the full local gate |
| `make help`           | every task                                                                                          |

## The render harness

`scripts/validate.sh` renders and validates everything a cluster would apply from this image, once per deploy tree and
signing mode (`{aws,google}` × `{keyless,keyed}`):

1. **kustomize-build** the deploy tree (common + flux + the cloud overlay).
2. **Substitute** `cluster-vars` and `github-arc-vars` from the fixtures in `tests/` the way the seeded Kustomization
   does (`postBuild.substituteFrom`), faithfully to the controller's roundtrip. Substitution is strict, so a variable
   neither ConfigMap publishes fails; and a null guard fails any `${VAR}`-bearing scalar that would become null on a
   cluster.
3. **Assert the seed contract**: the `flux/` objects carry exactly the names, namespace and prune label the
   `modules/application` seed creates. See [The seed contract](../concepts/seed-contract.md).
4. **Render every ResourceSet** with `flux-operator build resourceset` and the sample inputs under `tests/inputs/`.
5. **Guard the runners**: every image the rendered scale sets name sits under the platform mirror
   (`${CONTAINER_REGISTRY}/images/`), and exactly the architectures whose `GITHUB_ARC_<ARCH>_ENABLED` is `"true"` render
   a `HelmRelease linux-<arch>` (and, on aws, a `NodePool github-arc-<arch>`).
6. **kubeconform** the results against the Flux, flux-operator and vendored CRD schemas in `tests/schemas/`.

The application's vars come from `tests/github-arc-vars.env` (plus `github-arc-vars.aws.env` on aws), at the modules'
defaults. The keyed passes also source `tests/github-arc-vars.keyed.env`, which renders the other side of each gate:
arm64 off, a runner group, and an aws NodePool with no instance-family requirement.

The null guard runs a self-test first, so a guard that has rotted aborts the run rather than passing silently.

## The module tests

`make test-modules` runs `terraform test` in `modules/aws` and `modules/google`, against mocked providers. `modules/aws`
and `modules/google` call the cluster modules' `modules/application` from git, so `init` needs network access; nothing
else is reached.

## The task file

```toml
--8<-- "tasks.toml"
```
