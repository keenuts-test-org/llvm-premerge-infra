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
  name     = var.cluster_name
  location = "europe-west1-b"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Set the networking mode to VPC Native to enable IP aliasing, which is required
  # for adding windows nodes to the cluster.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}
}

resource "google_container_node_pool" "llvm_premerge_linux_service" {
  name       = "llvm-premerge-linux-service"
  location   = "europe-west1-b"
  cluster    = google_container_cluster.llvm_premerge.name
  node_count = 1

  node_config {
    machine_type = "e2-small"
  }
}

resource "google_container_node_pool" "llvm_premerge_linux" {
  name               = "llvm-premerge-linux"
  location           = "europe-west1-b"
  cluster            = google_container_cluster.llvm_premerge.name
  initial_node_count = 1

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 2
  }

  node_config {
    machine_type = "n1-highcpu-8"
    taint = [{
      key    = "premerge-platform"
      value  = "linux"
      effect = "NO_SCHEDULE"
    }]
    labels = {
      "premerge-platform" : "linux"
    }
  }
}

resource "google_container_node_pool" "llvm_premerge_windows" {
  name               = "llvm-premerge-windows"
  location           = "europe-west1-b"
  cluster            = google_container_cluster.llvm_premerge.name
  initial_node_count = 1

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 2
  }

  node_config {
    machine_type = "n1-highcpu-8"
    labels = {
      "premerge-platform" : "windows"
    }
    image_type = "WINDOWS_LTSC_CONTAINERD"
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

data "google_secret_manager_secret_version" "grafana_token" {
  secret = "llvm-premerge-testing-grafana-token"
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

resource "kubernetes_namespace" "llvm_premerge_windows_runners" {
  metadata {
    name = "llvm-premerge-windows-runners"
  }
}

resource "kubernetes_secret" "windows_github_pat" {
  metadata {
    name      = "github-token"
    namespace = "llvm-premerge-windows-runners"
  }

  data = {
    "github_token" = data.google_secret_manager_secret_version.github_pat.secret_data
  }

  type = "Opaque"
}


resource "kubernetes_config_map" "linux_container_pod_template" {
  metadata {
    name = "linux-container-pod-template"
    namespace = "llvm-premerge-linux-runners"
  }

  data = {
    "linux-container-pod-template.yaml": "${file("linux_container_pod_template.yaml")}"
  }
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

  depends_on = [kubernetes_namespace.llvm_premerge_linux_runners]
}

resource "helm_release" "github_actions_runner_set_windows" {
  name       = "llvm-premerge-windows-runners"
  namespace  = "llvm-premerge-windows-runners"
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  version    = "0.9.3"
  chart      = "gha-runner-scale-set"

  values = [
    "${file("windows_runner_values.yaml")}"
  ]

  depends_on = [kubernetes_namespace.llvm_premerge_windows_runners]
}

resource "helm_release" "grafana-k8s-monitoring" {
  name             = "grafana-k8s-monitoring"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "k8s-monitoring"
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 300

  values = [file("${path.module}/grafana_values.yaml")]

  set {
    name  = "cluster.name"
    value = var.cluster_name
  }

  set {
    name  = "externalServices.prometheus.host"
    value = var.externalservices_prometheus_host
  }

  set_sensitive {
    name  = "externalServices.prometheus.basicAuth.username"
    value = var.externalservices_prometheus_basicauth_username
  }

  set_sensitive {
    name  = "externalServices.prometheus.basicAuth.password"
    value = data.google_secret_manager_secret_version.grafana_token.secret_data
  }

  set {
    name  = "externalServices.loki.host"
    value = var.externalservices_loki_host
  }

  set_sensitive {
    name  = "externalServices.loki.basicAuth.username"
    value = var.externalservices_loki_basicauth_username
  }

  set_sensitive {
    name  = "externalServices.loki.basicAuth.password"
    value = data.google_secret_manager_secret_version.grafana_token.secret_data
  }

  set {
    name  = "externalServices.tempo.host"
    value = var.externalservices_tempo_host
  }

  set_sensitive {
    name  = "externalServices.tempo.basicAuth.username"
    value = var.externalservices_tempo_basicauth_username
  }

  set_sensitive {
    name  = "externalServices.tempo.basicAuth.password"
    value = data.google_secret_manager_secret_version.grafana_token.secret_data
  }

  set {
    name  = "opencost.opencost.exporter.defaultClusterId"
    value = var.cluster_name
  }

  set {
    name  = "opencost.opencost.prometheus.external.url"
    value = format("%s/api/prom", var.externalservices_prometheus_host)
  }
}
