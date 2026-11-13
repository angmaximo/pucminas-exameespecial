terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type    = string
  default = "puc-serverless-ia"
}

variable "region" {
  type    = string
  default = "us-central1"
}

# -----------------------------------------------------------------------------
# ETAPA 1: Tópico Pub/Sub principal, DLQ e Política de Dead-Letter
# -----------------------------------------------------------------------------
resource "google_pubsub_topic" "build_failures_dlq" {
  name = "build-failures-dlq"
}

resource "google_pubsub_subscription" "build_failures_dlq_sub" {
  name  = "build-failures-dlq-sub"
  topic = google_pubsub_topic.build_failures_dlq.name
}

resource "google_pubsub_topic" "build_failures" {
  name = "build-failures"
}

resource "google_pubsub_subscription" "build_failures_subscription" {
  name  = "build-failures-sub"
  topic = google_pubsub_topic.build_failures.name

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.build_failures_dlq.id
    max_delivery_attempts = 5
  }
}

# -----------------------------------------------------------------------------
# ETAPA 3: Secret Manager e IAM de Menor Privilégio
# -----------------------------------------------------------------------------
resource "google_service_account" "triage_agent_sa" {
  account_id   = "triage-agent-event-sa"
  display_name = "Service Account for Intelligent Triage Agent"
}

resource "google_secret_manager_secret" "oncall_secret" {
  secret_id = "oncall-webhook-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  secret_id = google_secret_manager_secret.oncall_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.triage_agent_sa.email}"
}

# Permissão para acessar o Firestore
resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.triage_agent_sa.email}"
}

# -----------------------------------------------------------------------------
# ETAPA 4: Configuração do Cloud Run / Cloud Function Gen 2 (Mitigação de Cold Start)
# -----------------------------------------------------------------------------
# Exemplo de configuração de serviço (Cloud Run / Function v2 Gen)
resource "google_cloud_run_v2_service" "triage_agent_service" {
  name     = "triage-agent-service"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.triage_agent_sa.email
    
    # Otimização de Cold Start: Mantém instâncias mínimas quentes
    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    containers {
      image = "gcr.io/${var.project_id}/triage-agent:latest"
      
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      # Injeção segura do Secret Manager como variável de ambiente
      secret_environment_variables {
        key        = "ONCALL_WEBHOOK_SECRET"
        secret     = google_secret_manager_secret.oncall_secret.secret_id
        version    = "latest"
      }
    }
  }
}