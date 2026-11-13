# Relatório Técnico — Exame Especial: Plataforma Serverless de Triagem Inteligente de Incidentes DevOps

**Aluno(a):** Ângelo  
**Disciplina:** Arquiteturas Serverless e Inteligência Artificial Aplicada  
**Repositório:** `puc-serveless-ia-event-driven` (Diretório: `exame-especial/`)  

---

## 1. Visão Geral e Objetivos

Este relatório técnico documenta a evolução da **Plataforma Serverless de Triagem Inteligente de Incidentes DevOps**, integrando conceitos avançados trabalhados ao longo da disciplina:
1. **Arquiteturas Event-Driven, Idempotência e Resiliência (DLQ)**.
2. **Agentes Autônomos com Vertex AI (Gemini), Function Calling e Loop ReAct**.
3. **Segurança (IAM de Menor Privilégio + Secret Manager) e CI/CD (Cloud Build)**.
4. **Observabilidade (Logs Estruturados) e Mitigação de Cold Start**.

---

## 2. Arquitetura da Solução e Fluxos

### 2.1. Diagrama Geral da Arquitetura (Mermaid)

```mermaid
graph TD
    Client[Pipeline CI/CD / GCP Monitoring] -->|Publica Falha| PubSubMain[Tópico Pub/Sub: build-failures]
    
    PubSubMain -->|Max Tentativas = 5 falhadas| DLQ[Dead-Letter Queue: build-failures-dlq]
    PubSubMain -->|Entrega Mensagem| CloudRun[Cloud Run / Cloud Function Gen 2]

    subgraph "Camada de Aplicação Serverless"
        CloudRun -->|1. Consulta Idempotência| Firestore[(Firestore: build_triages)]
        CloudRun -->|2. Injeta Segredo| SecretMgr[Secret Manager: oncall-webhook-secret]
        CloudRun -->|3. Executa Agente ReAct| VertexAI[Vertex AI / Gemini]
    end

    subgraph "Ferramentas de Função (Function Calling)"
        VertexAI -->|Chama| Tool1[local_get_build_logs]
        VertexAI -->|Chama| Tool2[local_trigger_pipeline_retry]
        VertexAI -->|Chama| Tool3[local_notify_oncall_team]
    end