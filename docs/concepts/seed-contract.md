# The seed contract

The cluster modules' `modules/application` creates two objects in `flux-system` through the `application-github-arc`
helm release, and keeps them under terraform on every apply. This image ships no copy of them: the seed decides
**which** build a cluster runs, and the image decides **what** that build deploys. Their names are a fixed contract
between the three repositories:

| Object                     | Name                   | Namespace     | Owner                              |
| -------------------------- | ---------------------- | ------------- | ---------------------------------- |
| `ResourceSetInputProvider` | `github-arc-manifests` | `flux-system` | terraform (`modules/{aws,google}`) |
| `ResourceSet`              | `github-arc-manifests` | `flux-system` | terraform (`modules/{aws,google}`) |
| `OCIRepository`            | `github-arc-manifests` | `flux-system` | `ResourceSet/github-arc-manifests` |
| `Kustomization`            | `github-arc`           | `flux-system` | `ResourceSet/github-arc-manifests` |
| `ConfigMap` (substitution) | `cluster-vars`         | `flux-system` | terraform (the cluster root)       |
| `ConfigMap` (substitution) | `github-arc-vars`      | `flux-system` | terraform (`modules/{aws,google}`) |

```mermaid
flowchart TD
  seed["terraform<br/>application-github-arc release"]
  rsip["ResourceSetInputProvider<br/>github-arc-manifests"]
  rs["ResourceSet<br/>github-arc-manifests"]
  oci["OCIRepository<br/>github-arc-manifests"]
  ks["Kustomization<br/>github-arc"]
  vars[("cluster-vars<br/>github-arc-vars")]
  seed -- "every apply" --> rsip & rs
  rsip -- "newest tag in<br/>image.semver / image.channel" --> rs
  rs --> oci & ks
  ks -- "applies ./&lt;PLATFORM_TREE&gt;" --> app["github-arc"]
  vars -. "postBuild.substituteFrom" .-> ks
```

## How it works

- **Terraform picks the build.** The modules' `image` (`semver`, `channel`) passes straight through to the seed: by
  default the newest release in `<1.0.0 >=0.1.0`, or a channel's newest immutable build. The ResourceSet turns the
  newest match into a digest-pinned, signature-verified `OCIRepository`, and the `Kustomization` that applies
  `./<PLATFORM_TREE>` (`./aws` or `./google`) from it, substituting from `cluster-vars` and `github-arc-vars`.
- **It waits on the platform.** The Kustomization depends on `kyverno-policies` and `arc` everywhere, and on
  `secret-sync` and `karpenter` on aws; the modules pass that set to the seed.
- **The range moves with the infrastructure.** A release that needs new infrastructure (node pools, roles, grants,
  secret containers) is a breaking release. The module version that adds that infrastructure also moves the range, so
  both land in the same apply. Within a range, a release must never need new infrastructure.
- **The image ships no seed objects.** An image that carried its own copy would have its Kustomization re-apply it on
  every reconcile and fight terraform.
- **Destroying the module uninstalls github-arc.** The ResourceSet finalizer garbage-collects the Kustomization, whose
  finalizer prunes the scale sets (and, on aws, the NodePools).

!!! danger "Keep the range honest"

    A range matching **no** tag empties the ResourceSet, which prunes the application. The `edge` channel follows
    every edge build unless `semver` bounds it (`^0.2.0-0`), so an edge cluster can run a breaking build before its
    infrastructure is applied.
