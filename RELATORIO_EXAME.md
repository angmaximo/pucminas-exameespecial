# Relatório Técnico — Exame Especial: Plataforma Serverless de Triagem Inteligente de Incidentes DevOps

**Aluno(a):** Ângelo Máximo Moreira Silva  
**Disciplina:** Arquiteturas Serverless e Inteligência Artificial Aplicada  
**Repositório:** `puc-serveless-ia-event-driven` (Diretório: `exame-especial/`)  

---

## 1. Visão Geral e Objetivos

Este relatório técnico documenta a implementação e evolução da **Plataforma Serverless de Triagem Inteligente de Incidentes DevOps**, integrando os conceitos centrais da disciplina:
1. **Arquitetura Event-Driven, Idempotência e Resiliência (DLQ)**.
2. **Agentes Autônomos com Vertex AI (Gemini), Function Calling e Loop ReAct**.
3. **Segurança Avançada (IAM de Menor Privilégio + Secret Manager) e Esteira CI/CD (Cloud Build)**.
4. **Observabilidade (Logs Estruturados em JSON), Mitigação de Cold Start e Warm Starts**.

---

## 2. Arquitetura da Solução e Fluxos

### 2.1. Diagrama Geral da Arquitetura (Mermaid)

```mermaid
graph TD
    Client[Pipeline CI/CD / GCP Monitoring] -->|Publica Falha| PubSubMain[Tópico Pub/Sub: build-failures]
    
    PubSubMain -->|Max Tentativas = 5 falhas| DLQ[Dead-Letter Queue: build-failures-dlq]
    PubSubMain -->|Entrega Mensagem| CloudFunc[Cloud Functions Gen 2 / Cloud Run]

    subgraph "Camada de Aplicação Serverless"
        CloudFunc -->|1. Consulta Idempotência| Firestore[(Firestore: build_triages)]
        CloudFunc -->|2. Injeta Segredo| SecretMgr[Secret Manager: oncall-webhook-secret]
        CloudFunc -->|3. Executa Agente ReAct| VertexAI[Vertex AI / Gemini 2.5 Flash]
    end

    subgraph "Ferramentas de Função (Function Calling)"
        VertexAI -->|Chama| Tool1[get_build_logs]
        VertexAI -->|Chama| Tool2[trigger_pipeline_retry]
        VertexAI -->|Chama| Tool3[notify_oncall_team]
    end

    sequenceDiagram
    participant PubSub as Pub/Sub Event
    participant Agent as Agente ReAct (Vertex AI)
    participant Firestore as Firestore (Idempotência)
    participant Tools as Ferramentas Locais

    PubSub->>Agent: Dispara evento de build com falha
    Agent->>Firestore: Consulta status do build_id na coleção build_triages
    alt Evento já processado (status == TRIAGED)
        Firestore-->>Agent: Retorna documento existente com status TRIAGED
        Agent->>Agent: Ignora evento por idempotência (Log estruturado INFO) e encerra
    else Evento inédito / pendente
        Firestore-->>Agent: Documento não encontrado
        Agent->>Agent: Inicia Loop ReAct com System Instructions
        Agent->>Tools: Invoca get_build_logs(build_id)
        Tools-->>Agent: Retorna logs (ex: build-303 com erro CRITICAL)
        alt Erro Crítico / Corrupção de Banco
            Agent->>Tools: Invoca notify_oncall_team(build_id, severity, summary)
            Tools-->>Agent: Confirma abertura de chamado on-call
        else Erro Transitório
            Agent->>Tools: Invoca trigger_pipeline_retry(build_id)
            Tools-->>Agent: Confirma reexecução
        end
        Agent->>Firestore: Persiste diagnóstico, passos e status TRIAGED
    end