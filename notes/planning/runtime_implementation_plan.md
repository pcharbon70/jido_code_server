# Jido.Code.Server Runtime Implementation Plan (Reconciled)

## 1. Scope

This document started as the implementation roadmap. It is now reconciled against the actual repository state as of **2026-02-28**.

Primary source inputs remain:

- `notes/research/architecture.md`
- `notes/research/module_specs.md`
- `notes/planning/conversation_agent_first_greenfield_plan.md`
- `notes/planning/phase9_hardening_report.md`

## 2. Current Architecture Contracts

1. `Project` is the isolation and policy boundary (supervision, assets, sandbox, tool execution, protocol allowlisting).
2. Conversation runtime is **agent-first** on `Jido.AgentServer` (`Jido.Code.Server.Conversation.Agent`) with a pure signal reducer domain.
3. `Jido.Signal` is the canonical runtime envelope for conversation ingest/processing.
4. Tool execution remains a single path: `Policy -> ToolRunner`.
5. `jido_conversation` is integrated via `Conversation.JournalBridge` for canonical timeline/context journaling.
6. Protocol adapters (MCP/A2A) remain translators over core project/conversation APIs.

## 3. Phase Status Snapshot (2026-02-28)

| Phase | Status | Reconciled Notes |
| --- | --- | --- |
| 0 - Program Setup and Bootstrap | Complete | OTP app, deps, test/lint baseline in place. |
| 1 - Engine Core and Public Facade | Complete | `Jido.Code.Server` and `Engine` lifecycle + facade APIs implemented. |
| 2 - Project Container and Conversation Lifecycle | Complete | Project supervision, layout, registries, conversation supervision implemented. |
| 3 - Shared Asset System | Complete | Asset loaders/store, reload, diagnostics, strict loading controls implemented. |
| 4 - Policy, Catalog, Tool Runner | Complete | Policy enforcement, schema validation, sandbox/network/env guardrails, unified runner implemented. |
| 5 - Conversation Runtime Core | Complete (superseded design) | Implemented as `Conversation.Agent` + domain/actions/instructions (not legacy `Conversation.Server/Loop`). |
| 6 - LLM + Tool Orchestration | Complete | LLM/tool closed loop, async tool paths, cancellation and result reinjection implemented. |
| 7 - Telemetry, Diagnostics, Watcher | Complete | Telemetry events, diagnostics surfaces, alert routing, watcher debounce behavior implemented. |
| 8 - Protocol Adapters (MCP/A2A) | Complete | Gateways/project servers implemented with per-project protocol allowlist enforcement. |
| 9 - Hardening, Performance, Release | Implemented; release sign-off pending | Hardening controls and benchmark harness implemented; manual sign-offs still open. |

## 4. Superseded Assumptions From Original Plan

1. **Original baseline statement was stale.**
   - Superseded: “documentation-only (no runtime scaffold yet)”.
   - Current: full runtime, tests, protocol gateways, and hardening suites are present.
2. **Conversation runtime module split changed.**
   - Superseded: `Conversation.Server` + `Conversation.Loop` wrapper model.
   - Current: `Conversation.Agent` with pure `Conversation.Domain.*`, `Conversation.Actions.*`, and `Conversation.Instructions.*`.
3. **Public conversation API changed from event-centric to signal-centric.**
   - Current facade: `conversation_call/4`, `conversation_cast/3`, `conversation_state/3`, `conversation_projection/4`.
4. **Sub-agent behavior is now explicit in runtime.**
   - Implemented with `Project.SubAgentManager`, `SubAgentTemplate`, and `SubAgentRef`.

## 5. Reconciled Phase Outcomes

### Phase 0

Delivered: application/runtime skeleton, dependency setup, CI/test baseline.

### Phase 1

Delivered:

- `lib/jido_code_server.ex`
- `lib/jido_code_server/engine.ex`
- `lib/jido_code_server/engine/supervisor.ex`
- `lib/jido_code_server/engine/project_registry.ex`
- `lib/jido_code_server/engine/project_supervisor.ex`

### Phase 2

Delivered:

- `lib/jido_code_server/project/supervisor.ex`
- `lib/jido_code_server/project/server.ex`
- `lib/jido_code_server/project/layout.ex`
- `lib/jido_code_server/project/conversation_registry.ex`
- `lib/jido_code_server/project/conversation_supervisor.ex`

### Phase 3

Delivered:

- `lib/jido_code_server/project/asset_store.ex`
- `lib/jido_code_server/project/loaders/*.ex`
- Asset list/get/search/reload + diagnostics integration in `Project.Server`

### Phase 4

Delivered:

- `lib/jido_code_server/project/policy.ex`
- `lib/jido_code_server/project/tool_catalog.ex`
- `lib/jido_code_server/project/tool_runner.ex`
- `lib/jido_code_server/project/task_supervisor.ex`
- `lib/jido_code_server/project/tool_action_bridge.ex`

### Phase 5

Delivered (agent-first implementation):

- `lib/jido_code_server/conversation/agent.ex`
- `lib/jido_code_server/conversation/domain/state.ex`
- `lib/jido_code_server/conversation/domain/reducer.ex`
- `lib/jido_code_server/conversation/domain/projections.ex`
- `lib/jido_code_server/conversation/actions/*.ex`
- `lib/jido_code_server/conversation/instructions/*.ex`

### Phase 6

Delivered:

- `lib/jido_code_server/conversation/llm.ex`
- `lib/jido_code_server/conversation/tool_bridge.ex`
- Instruction-driven LLM/tool side effects with queue reinjection and cancellation support

### Phase 7

Delivered:

- `lib/jido_code_server/telemetry.ex`
- `lib/jido_code_server/alert_router.ex`
- `lib/jido_code_server/project/watcher.ex`
- `Jido.Code.Server.incident_timeline/3` diagnostics surface

### Phase 8

Delivered:

- `lib/jido_code_server/protocol/mcp/gateway.ex`
- `lib/jido_code_server/protocol/mcp/project_server.ex`
- `lib/jido_code_server/protocol/a2a/gateway.ex`
- `lib/jido_code_server/protocol/a2a/project_server.ex`

### Phase 9

Delivered (technical controls):

- Hardening controls documented in `notes/planning/phase9_hardening_report.md`
- Benchmark harness in `lib/jido_code_server/benchmark/phase9_harness.ex`
- Operator task `mix phase9.bench`

Remaining for full closeout:

- Manual P0/P1 defect sweep confirmation
- Engineering/security/operations sign-off

## 6. Updated Module-to-Phase Mapping

| Module/Area | Phase |
| --- | --- |
| `Jido.Code.Server` facade + `Engine*` | 1 |
| `Project.Supervisor` / `Project.Server` / layout/registry/supervisor | 2 |
| `AssetStore` + `Project.Loaders.*` | 3 |
| `Policy` / `ToolCatalog` / `ToolRunner` / `TaskSupervisor` | 4 |
| `Conversation.Agent` + `Conversation.Domain.*` + `Conversation.Actions.*` | 5 |
| `Conversation.LLM` / `Conversation.ToolBridge` / `Conversation.Instructions.*` | 6 |
| `Telemetry` / `AlertRouter` / `Project.Watcher` / diagnostics | 7 |
| `Protocol.MCP.*` / `Protocol.A2A.*` | 8 |
| Hardening + benchmark (`Phase9Harness`, hardening tests/report) | 9 |

## 7. Remaining Plan-Close Items

1. Confirm “No open P0/P1 correctness or security defects” against current issue tracker/release board.
2. Complete release sign-offs:
   - Engineering
   - Security
   - Operations/on-call
3. Keep this reconciled document aligned with future architectural changes (especially cross-repo `jido_conversation` changes).
