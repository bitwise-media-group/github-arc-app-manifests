# Changelog

## 0.1.0 (2026-11-12)


### ⚠ BREAKING CHANGES

* modules/aws and modules/google replace manifests_semver with image = { semver, channel }, and no longer publish GITHUB_ARC_MANIFESTS_SEMVER or SIGNED_IDENTITY_GITHUB_ARC_MANIFESTS. The image's trees move from ./deploy/<tree> to ./<tree>, so a cluster on this module version needs an image built from this commit or later: apply only after its edge build is published.
* releases are tagged vX.Y.Z (promoted edge builds) instead of X.Y.Z, the edge/staging/stable/edge-next tags are gone, and the default signed_identity_subject is now release.yaml@refs/heads/main: re-apply the modules so clusters verify the new identity before the first release under this version.

### Features

* **aws:** install github-arc onto an eks-flux cluster ([d712a60](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/d712a602c84a80d54ae6df4a78a49e7e335760aa))
* follow the mirrored runner and dind image tags through input providers ([4f8fa2f](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/4f8fa2fe73d99d1aaac824a9e159bbd683fc1f7c))
* **google:** install github-arc onto a gke-flux cluster ([41ee29a](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/41ee29aca22f4592151cc1036375561f6326a280))
* let terraform own the seed and flatten the image to manifests/&lt;tree&gt; ([bc9fea0](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/bc9fea0c4a87b7518905eab882c0dc7d13669e6e))
* **manifests:** ship linux-amd64 and linux-arm64 runner scale sets ([3b02200](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/3b0220058fa302aa82782aec2c6f3eca5edd8a74))
* publish immutable edge builds and promote releases from the release pipeline ([272a63f](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/272a63f2dfbd524dadfcf148cf561a0bc091fa81))


### Bug Fixes

* **deps:** pin terraform-google-gke-flux to ddc4be2 ([fd1e201](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/fd1e20129b8fa78875ed479af7567bef625fb776))
* **deps:** update bitwise-media-group/github-workflows action to v8.1.1 ([#4](https://github.com/bitwise-media-group/github-arc-app-manifests/issues/4)) ([cda17a0](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/cda17a0d8fbdb505440ab3985fa982355541e012))
* **deps:** update bitwise-media-group/github-workflows action to v8.3.0 ([#20](https://github.com/bitwise-media-group/github-arc-app-manifests/issues/20)) ([6f13e7d](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/6f13e7db0ab9c36c3423628fce7a27b8dc6443e9))
* **deps:** update sigstore/cosign-installer action to v4.1.3 ([#10](https://github.com/bitwise-media-group/github-arc-app-manifests/issues/10)) ([190de0e](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/190de0e6715a60b49e747b0b0fc37694548afc10))
* **modules:** pin upper bound to &lt; major ([d556bc6](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/d556bc6c4a3092fa05006b8a03d1d400968b4579))
* **publish:** pre-create pull dirs and quieten cosign signing ([cd7d5e0](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/cd7d5e0e906fd341196be63a64638d73572bec21))
* **release:** start the first release at 0.1.0 ([4bcb920](https://github.com/bitwise-media-group/github-arc-app-manifests/commit/4bcb920f251ad8b186e65f9d9eb416f5ed2e7144))
