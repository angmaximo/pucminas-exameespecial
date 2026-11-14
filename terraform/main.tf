terraform {
  # Caso queira usar backend remoto, descomente e configure seu bucket:
  # backend "gcs" {
  #   bucket = "SEU-BUCKET-TFSTATE"
  #   prefix = "terraform/state/exame-especial"
  # }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "ID do projeto no Google Cloud"
  type        = string
  default     = "meu-projeto-puc"
}

variable "region" {
  description = "Região padrão dos recursos serverless"
  type        = string
  default     = "us-central1"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 1. Tópico Pub/Sub principal de falhas de build que acionará o Agente
resource "google_pubsub_topic" "build_failures" {
  name = "build-failures"
}

# ============================================================================
# ETAPA 1: Dead-Letter Queue (DLQ)
# ============================================================================
resource "google_pubsub_topic" "build_failures_dlq" {
  name = "build-failures-dlq"
}

resource "google_pubsub_subscription" "build_failures_sub" {
  name  = "build-failures-sub"
  topic = google_pubsub_topic.build_failures.name

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.build_failures_dlq.id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_subscription" "build_failures_dlq_sub" {
  name  = "build-failures-dlq-sub"
  topic = google_pubsub_topic.build_failures_dlq.name
}


# 2. Bucket e Código para a Função
resource "google_storage_bucket" "function_bucket" {
  name                        = "exame-especial-src-${random_id.bucket_suffix.hex}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/function-source.zip"
}

resource "google_storage_bucket_object" "function_code" {
  name   = "source-${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = data.archive_file.function_zip.output_path
}

# 3. Service Account dedicada para o Agente Orientado a Eventos (Menor Privilégio)
resource "google_service_account" "agent_sa" {
  account_id   = "triage-agent-event-sa"
  display_name = "Service Account do Agente de Triagem Event-Driven"
}

# 4. Permissões IAM necessárias
resource "google_project_iam_member" "vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent_sa.email}"
}

resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.agent_sa.email}"
}

# ============================================================================
# ETAPA 3: Secret Manager + IAM de Menor Privilégio
# ============================================================================
resource "google_secret_manager_secret" "oncall_webhook_secret" {
  secret_id = "oncall-webhook-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  secret_id = google_secret_manager_secret.oncall_webhook_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_sa.email}"
}


# 5. Cloud Function Gen 2 disparada por evento do Pub/Sub
resource "google_cloudfunctions2_function" "triage_agent" {
  name     = "triage-agent-event-driven"
  location = var.region
  build_config {
    runtime     = "python312"
    entry_point = "triage_agent_event_driven"
    source {
      storage_source {
        bucket = google_storage_bucket.function_bucket.name
        object = google_storage_bucket_object.function_code.name
      }
    }
  }
  service_config {
    # ETAPA 4: Otimização de Cold Start (min_instance_count = 1 mantém instâncias quentes)
    min_instance_count = 1
    max_instance_count = 3
    available_memory   = "512Mi"
    timeout_seconds    = 120
    environment_variables = {
      GCP_PROJECT = var.project_id
      GCP_REGION  = var.region
    }
    service_account_email = google_service_account.agent_sa.email

    # ETAPA 3: Injeção do segredo do Secret Manager como variável de ambiente
    secret_environment_variables {
      key        = "ONCALL_WEBHOOK_SECRET"
      project_id = var.project_id
      secret_id  = google_secret_manager_secret.oncall_webhook_secret.secret_id
      version    = "latest"
    }
  }
  event_trigger {
    event_type   = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic = google_pubsub_topic.build_failures.id
    retry_policy = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_project_iam_member.vertex_ai_user,
    google_project_iam_member.firestore_user,
    google_secret_manager_secret_iam_member.secret_accessor
  ]
}

output "topic_id" {
  value = google_pubsub_topic.build_failures.id
}