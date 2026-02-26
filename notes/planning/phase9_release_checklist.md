# Jido.Code.Server Phase 9 Release Checklist

## Quality Gates

- [ ] `mix ci` passes on the release branch.
- [ ] `test/jido_code_server/runtime_hardening_test.exs` passes.
- [ ] Phase 9 benchmark harness runs cleanly (`mix phase9.bench`) for the target workload profile.
- [ ] No open P0/P1 correctness or security defects.

## Security Gates

- [ ] Tool schema validation rejects malformed payloads.
- [ ] Tool schema validation recursively enforces nested object payloads (for example `command.run.*.params` and `workflow.run.*.inputs`).
- [ ] Policy decisions emit `policy.allowed` / `policy.denied` with auditable context.
- [ ] Correlation IDs propagate across ingest, LLM lifecycle, tool execution, and policy decisions.
- [ ] Sandbox escape attempts emit `security.sandbox_violation`.
- [ ] Sandbox path validation covers nested map/list arguments, JSON wrapper payloads, and opaque serialized keyed payload blobs containing path-like keys.
- [ ] Outside-root exceptions require `outside_root_allowlist` entries with `reason_code` and emit `security.sandbox_exception_used`.
- [ ] Malformed `outside_root_allowlist` entries are rejected at startup via `{:invalid_runtime_opt, :outside_root_allowlist, ...}`.
- [ ] Sensitive file paths are denylisted by default (including outside-root allowlist exceptions unless explicitly sensitive-allowlisted) and emit `security.sensitive_path_denied` when blocked.
- [ ] Tool results with sensitive artifacts are flagged and emit `security.sensitive_artifact_detected`.
- [ ] Artifact size caps (`tool_max_artifact_bytes`) apply to nested command/workflow execution artifacts, not only top-level tool result keys.
- [ ] Network-capable tools are deny-by-default and emit `security.network_denied` when blocked.
- [ ] `network_allowlist` filtering is validated for allowlisted and non-allowlisted endpoints (including nested targets, JSON-encoded targets, JSON wrapper payloads, and opaque serialized payload blobs).
- [ ] High-risk network protocols are deny-by-default unless explicitly allowlisted via `network_allowed_schemes`.
- [ ] Telemetry redaction masks secret/token patterns in recent errors.
- [ ] Repeated timeout escalation emits `security.repeated_timeout_failures`.
- [ ] Project and conversation concurrency limits both enforce (`tool_max_concurrency`, `tool_max_concurrency_per_conversation`).
- [ ] `conversation.cancel` emits deterministic `conversation.tool.cancelled` events with reason `conversation_cancelled` when pending tool calls exist.
- [ ] Async tool requests (`meta.run_mode = "async"`) emit completion/failure events via conversation runtime and are cancellable by `conversation.cancel`.
- [ ] Timeout and cancellation paths terminate tracked child processes and emit `conversation.tool.child_processes_terminated`.
- [ ] Project startup rejects malformed runtime options with deterministic `{:invalid_runtime_opt, key, reason}` errors.
- [ ] Project startup rejects unknown runtime option keys (strict startup option allowlist).
- [ ] Command/workflow `env` passthrough is deny-by-default, allowlisted via `tool_env_allowlist`, and denied attempts emit `security.env_denied`.
- [ ] Optional stronger command isolation mode is available behind runtime config (`command_executor`) with startup allowlist validation (`workspace_shell` alias/module).
- [ ] Workspace-backed command executor uses per-execution unique workspace IDs to avoid concurrent mount/session collisions.
- [ ] Command/workflow-backed tools execute valid markdown definitions through `jido_command`/`jido_workflow`; invalid definitions degrade to preview compatibility mode.
- [ ] Protocol adapters enforce per-project `protocol_allowlist` boundaries and denied access emits `security.protocol_denied`.

## Reliability Gates

- [ ] Loader parse failure paths are tested and non-crashing.
- [ ] `strict_asset_loading` fail-fast startup mode is validated for loader parse errors.
- [ ] LLM adapter failure path emits `llm.failed` and keeps conversation runtime available.
- [ ] Watcher storm behavior remains debounced and stable.
- [ ] Multi-project concurrent conversation workload validates isolation.
- [ ] Asset-backed command/workflow tools publish definition-aware `input_schema` metadata when markdown definitions are valid.

## Operational Readiness

- [ ] Runbook is current: `notes/planning/phase9_operations_runbook.md`.
- [ ] Hardening report is current: `notes/planning/phase9_hardening_report.md`.
- [ ] Runtime guardrail overrides (`tool_timeout_ms`, `tool_max_output_bytes`, etc.) are documented and test-covered.
- [ ] Incident timeline extraction (`Jido.Code.Server.incident_timeline/3`) is validated with bounded and correlation-filtered queries.
- [ ] Alert routing is configured for security and timeout escalation signals (`alert_signal_events`, `alert_router`).

## Sign-Off

- [ ] Engineering sign-off
- [ ] Security sign-off
- [ ] Operations/on-call sign-off
