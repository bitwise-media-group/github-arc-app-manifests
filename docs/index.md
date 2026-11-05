---
title: github-arc-app-manifests
template: home.html
hide:
  - navigation
  - toc
---

<!--
  The home page is rendered entirely by overrides/home.html (the landing).
  This body only provides the page title and meta description for the <head>.
-->

Self-hosted GitHub Actions runners for the platform clusters: two Actions Runner Controller scale sets
(`linux-amd64`, `linux-arm64`) on dedicated scale-to-zero capacity, shipped as a cosign-signed OCI artifact seeded once
by terraform and owned by flux from then on, plus the per-cloud terraform modules that install it.
