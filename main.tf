terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
}

provider "google" {
  project = "llvm-premerge-checks"
}

data "google_client_config" "current" {}

resource "google_container_cluster" "llvm_premerge" {
  name     = "llvm-premerge"
  location = "us-central1-a"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_container_node_pool" "llvm_premerge_linux_service" {
  name       = "llvm-premerge-linux-service"
  location   = "us-central1-a"
  cluster    = google_container_cluster.llvm_premerge.name
  node_count = 1

  node_config {
    machine_type = "e2-small"
  }
}

resource "google_container_node_pool" "llvm_premerge_linux" {
  name     = "llvm-premerge-linux"
  location = "us-central1-a"
  cluster  = google_container_cluster.llvm_premerge.name

  autoscaling {
    max_node_count = 2
  }

  node_config {
    machine_type = "n1-highcpu-8"
  }
}

provider "helm" {
  kubernetes {
    host                   = google_container_cluster.llvm_premerge.endpoint
    token                  = data.google_client_config.current.access_token
    client_certificate     = base64decode(google_container_cluster.llvm_premerge.master_auth.0.client_certificate)
    client_key             = base64decode(google_container_cluster.llvm_premerge.master_auth.0.client_key)
    cluster_ca_certificate = base64decode(google_container_cluster.llvm_premerge.master_auth.0.cluster_ca_certificate)
  }
}

data "google_secret_manager_secret_version" "github_pat" {
  secret = "llvm-premerge-testing-github-pat"
}

provider "kubernetes" {
  host  = "https://${google_container_cluster.llvm_premerge.endpoint}"
  token = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.llvm_premerge.master_auth[0].cluster_ca_certificate,
  )
}

resource "kubernetes_namespace" "llvm_premerge_linux" {
  metadata {
    name = "llvm-premerge-linux"
  }
}

resource "kubernetes_namespace" "llvm_premerge_linux_runners" {
  metadata {
    name = "llvm-premerge-linux-runners"
  }
}

resource "kubernetes_secret" "github_pat" {
  metadata {
    name      = "github-token"
    namespace = "llvm-premerge-linux-runners"
  }

  data = {
    "github_token" = data.google_secret_manager_secret_version.github_pat.secret_data
  }

  type = "Opaque"
}

resource "helm_release" "github_actions_runner_controller" {
  name       = "llvm-premerge-linux"
  namespace  = "llvm-premerge-linux"
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  version    = "0.9.3"
  chart      = "gha-runner-scale-set-controller"

  depends_on = [
    kubernetes_namespace.llvm_premerge_linux
  ]
}

resource "helm_release" "github_actions_runner_set" {
  name       = "llvm-premerge-linux-runners"
  namespace  = "llvm-premerge-linux-runners"
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  version    = "0.9.3"
  chart      = "gha-runner-scale-set"

  values = [
    "${file("linux_runners_values.yaml")}"
  ]
}