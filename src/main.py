import os
import json
import sys
from google.cloud import firestore
import vertexai
from vertexai.generative_models import GenerativeModel, Tool, FunctionDeclaration

# Inicialização do Firestore e Vertex AI
db = firestore.Client()

# -----------------------------------------------------------------------------
# ETAPA 4: Função Auxiliar de Logs Estruturados
# -----------------------------------------------------------------------------
def log_structured(severity: str, message: str, build_id: str = None, **kwargs):
    log_entry = {
        "severity": severity,
        "message": message,
    }
    if build_id:
        log_entry["build_id"] = build_id
    log_entry.update(kwargs)
    print(json.dumps(log_entry), flush=True)


# -----------------------------------------------------------------------------
# ETAPA 1: Controle de Idempotência no Firestore
# -----------------------------------------------------------------------------
def check_idempotency(build_id: str) -> bool:
    try:
        doc_ref = db.collection("build_triages").document(build_id)
        doc = doc_ref.get()
        if doc.exists:
            data = doc.to_dict()
            if data.get("status") == "TRIAGED":
                return True
    except Exception as e:
        log_structured("ERROR", f"Erro ao verificar idempotência: {str(e)}", build_id=build_id)
    return False

def save_triage_status(build_id: str, status: str, details: dict):
    try:
        doc_ref = db.collection("build_triages").document(build_id)
        doc_ref.set({
            "status": status,
            "details": details,
            "timestamp": firestore.SERVER_TIMESTAMP
        }, merge=True)
    except Exception as e:
        log_structured("ERROR", f"Erro ao salvar status no Firestore: {str(e)}", build_id=build_id)


# -----------------------------------------------------------------------------
# ETAPA 2: Ferramentas Locais e Cenário de Teste (build-303)
# -----------------------------------------------------------------------------
def local_get_build_logs(build_id: str) -> str:
    logs_db = {
        "build-303": "CRITICAL: Database corruption detected in production cluster. Integrity checks failed on primary node storage.",
        "build-101": "ERROR: ModuleNotFoundError: No module named 'fastapi'",
        "build-202": "WARNING: Deprecated python version detected in build pipeline."
    }
    return logs_db.get(build_id, f"Logs not found for build {build_id}")

def local_trigger_pipeline_retry(build_id: str) -> str:
    log_structured("INFO", f"Pipeline retry acionado para o build {build_id}", build_id=build_id)
    return f"Pipeline retry successfully triggered for build {build_id}."

def local_notify_oncall_team(build_id: str, severity: str, error_summary: str) -> str:
    webhook_url = os.environ.get("ONCALL_WEBHOOK_SECRET", "mock-webhook-url")
    log_structured("WARNING", f"Alerta On-Call enviado para equipe de plantão", build_id=build_id, severity=severity, summary=error_summary)
    return f"Incident ticket successfully opened for build {build_id} with severity {severity}."


# Declarações de Ferramentas Vertex AI (Function Calling)
get_build_logs_decl = FunctionDeclaration(
    name="local_get_build_logs",
    description="Obtém os logs brutos de um build específico a partir do seu ID.",
    parameters={
        "type": "OBJECT",
        "properties": {"build_id": {"type": "STRING", "description": "ID do build."}},
        "required": ["build_id"]
    }
)

trigger_pipeline_retry_decl = FunctionDeclaration(
    name="local_trigger_pipeline_retry",
    description="Reinicia a pipeline de CI/CD para o build especificado.",
    parameters={
        "type": "OBJECT",
        "properties": {"build_id": {"type": "STRING", "description": "ID do build."}},
        "required": ["build_id"]
    }
)

notify_oncall_decl = FunctionDeclaration(
    name="local_notify_oncall_team",
    description="Aciona o time de plantão (on-call) enviando um alerta crítico com severidade e resumo do erro.",
    parameters={
        "type": "OBJECT",
        "properties": {
            "build_id": {"type": "STRING", "description": "ID do build."},
            "severity": {"type": "STRING", "description": "Severidade do incidente (HIGH, CRITICAL)."},
            "error_summary": {"type": "STRING", "description": "Resumo detalhado do erro."}
        },
        "required": ["build_id", "severity", "error_summary"]
    }
)

devops_tools = Tool(
    function_declarations=[
        get_build_logs_decl,
        trigger_pipeline_retry_decl,
        notify_oncall_decl
    ]
)