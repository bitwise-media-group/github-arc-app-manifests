# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    # the floor terraform-google-gke-flux's modules/application carries and
    # the ceiling it shares with modules/node-pool, so the three never
    # disagree
    google = {
      source  = "hashicorp/google"
      version = ">= 7.46, < 8.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
