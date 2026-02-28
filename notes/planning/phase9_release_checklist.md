# Jido.Code.Server Phase 9 Release Checklist

## Evidence Snapshot (2026-02-28)

- `mix ci`: pass (`146 tests, 0 failures`; Credo clean)
- `mix test test/jido_code_server/runtime_hardening_test.exs`: pass (`55 tests, 0 failures`)
- `mix phase9.bench`: pass (`projects started=3/3`, `conversations started=12/12`, `projection checks failed=0`)
- Detailed control and coverage evidence: `notes/planning/phase9_hardening_report.md`

## Quality Gates

- [x] `mix ci` passes on the release branch.
- [x] `test/jido_code_server/runtime_hardening_test.exs` passes.
- [x] Phase 9 benchmark harness runs cleanly (`mix phase9.bench`) for the target workload profile.
- [ ] No open P0/P1 correctness or security defects.

## Security Gates

- [x] Tool schema validation rejects malformed payloads.
- [x] Tool schema validation recursively enforces nested object payloads (for example `command.run.*.params` and `workflow.run.*.inputs`).
- [x] Policy decisions emit `policy.allowed` / `policy.denied` with auditable context.
- [x] Correlation IDs propagate across ingest, LLM lifecycle, tool execution, and policy decisions.
- [x] Sandbox escape attempts emit `security.sandbox_violation`.
- [x] Sandbox path validation covers nested map/list arguments, JSON wrapper payloads, and opaque serialized keyed payload blobs containing path-like keys.
- [x] Outside-root exceptions require `outside_root_allowlist` entries with `reason_code` and emit `security.sandbox_exception_used`.
- [x] Malformed `outside_root_allowlist` entries are rejected at startup via `{:invalid_runtime_opt, :outside_root_allowlist, ...}`.
- [x] Sensitive file paths are denylisted by default (including outside-root allowlist exceptions unless explicitly sensitive-allowlisted) and emit `security.sensitive_path_denied` when blocked.
- [x] Tool results with sensitive artifacts are flagged and emit `security.sensitive_artifact_detected`.
- [x] Artifact size caps (`tool_max_artifact_bytes`) apply to nested command/workflow execution artifacts, not only top-level tool result keys.
- [x] Network-capable tools are deny-by-default and emit `security.network_denied` when blocked.
- [x] `network_allowlist` filtering is validated for allowlisted and non-allowlisted endpoints (including nested targets, JSON-encoded targets, JSON wrapper payloads, and opaque serialized payload blobs).
- [x] High-risk network protocols are deny-by-default unless explicitly allowlisted via `network_allowed_schemes`.
- [x] Telemetry redaction masks secret/token patterns in recent errors.
- [x] Repeated timeout escalation emits `security.repeated_timeout_failures`.
- [x] Project and conversation concurrency limits both enforce (`tool_max_concurrency`, `tool_max_concurrency_per_conversation`).
- [x] `conversation.cancel` emits deterministic `conversation.tool.cancelled` events with reason `conversation_cancelled` when pending tool calls exist.
- [x] Async tool requests (`meta.run_mode = "async"`) emit completion/failure events via conversation runtime and are cancellable by `conversation.cancel`.
- [x] Timeout and cancellation paths terminate tracked child processes and emit `conversation.tool.child_processes_terminated`.
- [x] Project startup rejects malformed runtime options with deterministic `{:invalid_runtime_opt, key, reason}` errors.
- [x] Project startup rejects unknown runtime option keys (strict startup option allowlist).
- [x] Command/workflow `env` passthrough is deny-by-default, allowlisted via `tool_env_allowlist`, and denied attempts emit `security.env_denied`.
- [x] Optional stronger command isolation mode is available behind runtime config (`command_executor`) with startup allowlist validation (`workspace_shell` alias/module).
- [x] Workspace-backed command executor uses per-execution unique workspace IDs to avoid concurrent mount/session collisions.
- [x] Command/workflow-backed tools execute valid markdown definitions through `jido_command`/`jido_workflow`; invalid definitions degrade to preview compatibility mode.
- [x] Protocol adapters enforce per-project `protocol_allowlist` boundaries and denied access emits `security.protocol_denied`.

## Reliability Gates

- [x] Loader parse failure paths are tested and non-crashing.
- [x] `strict_asset_loading` fail-fast startup mode is validated for loader parse errors.
- [x] LLM adapter failure path emits `llm.failed` and keeps conversation runtime available.
- [x] Watcher storm behavior remains debounced and stable.
- [x] Multi-project concurrent conversation workload validates isolation.
- [x] Asset-backed command/workflow tools publish definition-aware `input_schema` metadata when markdown definitions are valid.

## Operational Readiness

- [x] Runbook is current: `notes/planning/phase9_operations_runbook.md`.
- [x] Hardening report is current: `notes/planning/phase9_hardening_report.md`.
- [x] Runtime guardrail overrides (`tool_timeout_ms`, `tool_max_output_bytes`, etc.) are documented and test-covered.
- [x] Incident timeline extraction (`Jido.Code.Server.incident_timeline/3`) is validated with bounded and correlation-filtered queries.
- [x] Alert routing is configured for security and timeout escalation signals (`alert_signal_events`, `alert_router`).

## Sign-Off

- [ ] Engineering sign-off
- [ ] Security sign-off
- [ ] Operations/on-call sign-off
