# github-arc-app-manifests

Self-hosted GitHub Actions runners as a self-owned **application image** for the platform clusters: two Actions Runner
Controller scale sets, `linux-amd64` and `linux-arm64`, published as `oci://<registry>/manifests/github-arc`, plus the
per-cloud terraform modules that install it onto a cluster.

Scaffolded from [patchy-app-manifests](https://github.com/bitwise-media-group/patchy-app-manifests); see the
documentation site at <https://oss.bitwisemedia.uk/github-arc-app-manifests/>.
