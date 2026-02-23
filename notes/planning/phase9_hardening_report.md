# Jido.Code.Server Phase 9 Hardening Report

## Scope

- Phase: `9 - Hardening, Performance, and Release Readiness`
- Runtime namespace: `Jido.Code.Server`
- Focus areas implemented in this change:
  - Tool input/output safety guards
  - Policy decision auditability and telemetry
  - Telemetry secret redaction for diagnostics persistence
  - Correlation ID propagation across ingest, LLM, tool execution, and policy decisions
  - Bounded incident timeline extraction across conversation and telemetry streams
  - Explicit outside-root sandbox exceptions with reason-coded allowlisting and security telemetry
  - Conversation-scoped tool concurrency quotas
  - Deterministic cancellation events for pending tool calls
  - Async tool execution bridge with cancellable in-flight task tracking
  - Runtime option validation and normalization at project start
  - Environment-passthrough controls for command/workflow tools
  - Configurable alert routing for escalation telemetry signals
  - Protocol boundary allowlisting for MCP/A2A adapter exposure
  - Per-project strict asset loading fail-fast mode
  - Synthetic benchmark harness for repeatable load/soak validation
  - Command runtime bridge via `jido_command` for valid command markdown definitions
  - Nested artifact guardrail enforcement for command/workflow runtime execution payloads

## Implemented Controls

### 1. Tool schema validation gate

- All tool calls are now schema-validated before policy and execution in:
  - `lib/jido_code_server/project/tool_runner.ex`
- Enforced checks:
  - required keys
  - additional-property rejection when `additionalProperties` is `false`
  - primitive type validation for known schema types
- Failure surface:
  - returns `{:invalid_tool_args, ...}` with deterministic reason payloads.

### 2. Tool output and artifact size caps

- Tool runner now enforces:
  - `tool_max_output_bytes`
  - `tool_max_artifact_bytes`
  - configured via `Jido.Code.Server.Config`
- Default values:
  - output: `262_144` bytes
  - artifact: `131_072` bytes
- Oversized payloads are blocked with:
  - `{:output_too_large, actual, max}`
  - `{:artifact_too_large, index, actual, max}`

### 3. Timeout escalation telemetry

- Tool runner tracks timeout counts per `{project_id, tool}`.
- Emits:
  - `tool.timeout` on each timeout
  - `security.repeated_timeout_failures` when threshold is reached
- Threshold configured by:
  - `tool_timeout_alert_threshold` (default `3`)

### 4. Policy audit records and security signals

- Policy authorization now records every decision with:
  - `project_id`
  - `conversation_id`
  - `tool_name`
  - `reason`
  - timestamp
- Policy emits:
  - `policy.allowed`
  - `policy.denied`
  - `security.sandbox_violation` for outside-root path denial
- Recent policy decisions are exposed in project diagnostics.

### 5. Secret redaction gate on telemetry

- Telemetry payloads are sanitized before emission and persistence.
- Redaction applies to:
  - sensitive key names (`token`, `secret`, `password`, `api_key`, `authorization`, etc.)
  - known token patterns (OpenAI-style keys, GitHub PATs, AWS access keys, Slack token patterns, Bearer values)
- Recent error diagnostics now store redacted content only.

### 6. Sensitive artifact classification in tool results

- Tool runner now scans tool result payloads for sensitive key/value indicators.
- If detected, successful tool responses are annotated with:
  - `risk_flags: ["sensitive_artifact_detected"]`
  - `sensitivity_findings_count`
  - `sensitivity_finding_kinds`
- Security telemetry emits:
  - `security.sensitive_artifact_detected`
- This creates a non-blocking detection path for potentially sensitive tool outputs.

### 7. Sensitive file-path denylist controls

- Policy now blocks denylisted sensitive file-path access by default for path-like tool args.
- Default denylist covers common credential file patterns:
  - `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`
- Project overrides:
  - `sensitive_path_denylist`
  - `sensitive_path_allowlist` (explicit exception path patterns)
- Denied attempts return:
  - `:sensitive_path_denied`
- Security telemetry emits:
  - `security.sensitive_path_denied`

### 8. Network egress policy controls

- Tool metadata now marks network-capable tools (`command.run.*`, `workflow.run.*`) in `ToolCatalog`.
- Policy enforces network egress controls:
  - default deny (`network_egress_policy: :deny`)
  - explicit enable (`:allow`)
  - optional `network_allowlist` endpoint/domain filtering when enabled
  - protocol allowlist guardrail via `network_allowed_schemes` (default `["http", "https"]`)
- Network target extraction now traverses nested map/list payloads for network target keys
  (`url`/`uri`/`host`/`domain`/`endpoint`) instead of only top-level args.
- Network checks now also decode JSON-encoded values under network target keys, so
  serialized endpoint payloads are enforced by allowlist/protocol guards.
- JSON payload wrappers under non-network keys are decoded during traversal, so
  nested network target fields (for example under `payload`) are enforced.
- Opaque serialized blobs are scanned for URL and keyed endpoint markers, so
  non-JSON text payloads still participate in allowlist/protocol guardrails.
- Disallowed protocols are denied with:
  - `:network_protocol_denied`
- Policy telemetry now emits security signal on denied network attempts:
  - `security.network_denied`

### 9. Correlation ID propagation across runtime boundaries

- Conversation ingest now guarantees a correlation ID on every incoming event and propagates it to emitted events.
- LLM lifecycle events (`llm.started`, `assistant.delta`, `tool.requested`, `assistant.message`, `llm.completed`) carry the same correlation ID.
- Tool bridge and tool runner propagate correlation ID through:
  - tool call metadata
  - tool response payloads (`tool.completed`, `tool.failed`, timeout/escalation telemetry)
  - policy decision records (`recent_decisions`, `policy.allowed`, `policy.denied`)
- This enables end-to-end incident stitching by `project_id` + `conversation_id` + `correlation_id`.

### 10. Incident timeline extraction for response workflows

- Runtime API now exposes:
  - `Jido.Code.Server.incident_timeline(project_id, conversation_id, opts \\ [])`
- Timeline payload merges:
  - conversation timeline events
  - recent telemetry events for the same conversation
- Bound and filters:
  - `limit` option (default `100`, capped at `500`)
  - optional `correlation_id` filter for focused incident slicing
- Response payload includes:
  - `total_entries` before limit trim
  - bounded `entries` sorted by event time

### 11. Outside-root allowlist exceptions with reason codes

- Policy now supports explicit outside-root path exceptions through:
  - `outside_root_allowlist`
  - entry shape: `%{path | pattern, reason_code}`
- Exception behavior:
  - outside-root paths remain deny-by-default
  - exception only applies when path pattern matches and `reason_code` is non-empty
  - malformed entries (missing `path`/`pattern` or `reason_code`) are rejected at project startup
- Allowed exception attempts remain auditable via policy decision metadata:
  - `outside_root_exception_reason_codes`
- Security telemetry emits:
  - `security.sandbox_exception_used` with `reason_code`

### 12. Conversation-scoped tool concurrency quotas

- Tool runner now enforces two independent capacity controls:
  - `tool_max_concurrency` (project-wide in-flight limit)
  - `tool_max_concurrency_per_conversation` (per-conversation in-flight limit; default `4`)
- Enforcement details:
  - per-conversation counters are tracked by `{project_id, conversation_id}`
  - calls without a conversation ID remain governed by project-wide limits only
- Over-limit calls fail fast with:
  - `:conversation_max_concurrency_reached`
- Runtime diagnostics include:
  - `runtime_opts[:tool_max_concurrency_per_conversation]`

### 13. Deterministic pending-tool cancellation events

- Conversation cancellation now emits deterministic tool cancellation events when pending calls exist:
  - event type: `tool.cancelled`
  - reason payload: `"conversation_cancelled"`
- Correlation behavior:
  - `tool.cancelled` events inherit correlation from the triggering `conversation.cancel` event.
- State behavior:
  - pending tool calls are cleared on `conversation.cancel`
  - pending projection is consistent with emitted cancellation events (`pending_tool_calls == []` after cancel)

### 14. Async bridge task tracking and cancellation

- Tool bridge now supports async request mode (`meta.run_mode = "async"`) for `tool.requested` events.
- Async execution model:
  - `ToolBridge` starts background tool tasks through `ToolRunner.run_async/3`
  - `Conversation.Server` ingests async result messages and emits `tool.completed` / `tool.failed` events
- Cancellable behavior:
  - pending async task PIDs are tracked per `{project_id, conversation_id}`
  - `conversation.cancel` terminates tracked in-flight tasks and suppresses stale late-arriving task results
  - timeout and cancellation paths terminate registered child processes and emit `tool.child_processes_terminated`
- Test coverage validates:
  - async completion updates timeline and clears `pending_tool_calls`
  - cancellation path emits `tool.cancelled` and avoids stale `tool.completed` after cancel

### 15. Runtime option validation and normalization

- `Engine.start_project/2` now validates runtime option shapes before supervisor startup.
- Validation covers:
  - positive integer guards (`tool_timeout_ms`, `tool_max_output_bytes`, etc.)
  - non-negative integer guards (`tool_max_concurrency_per_conversation`)
  - boolean guards (`watcher`, `conversation_orchestration`, `strict_asset_loading`)
  - list-of-string guards for allow/deny and path/network list options
  - `network_egress_policy` value validation with normalization from `"allow"/"deny"` to atoms
  - optional LLM option type checks (`llm_model`, `llm_system_prompt`, `llm_temperature`, `llm_max_tokens`)
  - strict reason-coded outside-root allowlist entry checks
  - strict option-key allowlist; unknown startup options are rejected
- Invalid options fail fast with deterministic errors:
  - `{:invalid_runtime_opt, key, reason}`
- This prevents silent misconfiguration from weakening runtime guardrails (for example nil/invalid list overrides).

### 16. Environment inheritance guardrails

- Command/workflow tool calls now enforce explicit env passthrough controls:
  - `env` payload is denied by default
  - allowlist override via runtime option `tool_env_allowlist`
- Enforcement behavior:
  - only `command.run.*` and `workflow.run.*` tools apply this control
  - `env` must be a map when provided; non-map payloads are rejected
  - env keys not in allowlist are rejected with `{:env_vars_not_allowed, denied_keys}`
- Security telemetry emits:
  - `security.env_denied` for denied env-key usage and invalid env payload shapes

### 17. Alert routing for escalation telemetry

- Telemetry now supports routing selected high-severity signals to an external handler:
  - `alert_signal_events`
  - `alert_router`
- Default escalation signal set:
  - `security.sandbox_violation`
  - `security.repeated_timeout_failures`
- Router contract supports:
  - `{module, function}` receiving `(event_name, payload, metadata)`
  - `{module, function, extra_args}` receiving `(event_name, payload, metadata, ...extra_args)`
- Dispatch is best-effort and non-fatal; router failures do not crash runtime telemetry emission.

### 18. Strict asset loading runtime mode

- Runtime startup now supports project-level strict loader behavior:
  - `strict_asset_loading` runtime option (boolean)
- In strict mode:
  - startup fails fast when loader parse errors are present (`:asset_load_failed`)
- In lenient mode:
  - project starts with diagnostics errors captured, preserving runtime availability
- This makes loader strictness an explicit per-project reliability/safety control.

### 19. Phase 9 synthetic benchmark harness

- Added reusable benchmark module:
  - `Jido.Code.Server.Benchmark.Phase9Harness.run/1`
- Added operator-facing task:
  - `mix phase9.bench`
- Harness behavior:
  - bootstraps temporary seeded project roots
  - starts configurable project/conversation fan-out
  - dispatches concurrent `user.message` workloads
  - validates projection integrity and reports latency percentiles
  - emits structured pass/fail report with per-step failure details
- This provides repeatable non-unit load/soak evidence beyond normal test execution.

### 20. Protocol boundary allowlisting for MCP/A2A adapters

- Projects can now explicitly control protocol exposure with runtime option:
  - `protocol_allowlist` (default `["mcp", "a2a"]`)
- Gateway enforcement:
  - MCP operations (`tools.list`, `tools.call`, `message.send`) require `mcp` in allowlist
  - A2A operations (`agent.card`, `task.*`) require `a2a` in allowlist
- Denied protocol access now returns deterministic errors:
  - `{:protocol_denied, "mcp"}` / `{:protocol_denied, "a2a"}`
- Security telemetry emits:
  - `security.protocol_denied` with protocol and operation context for triage.

### 21. Command and workflow runtime bridges with compatibility fallback

- Asset-backed command/workflow tools now attempt real execution when markdown assets contain
  valid runtime definitions:
  - commands via `jido_command`
  - workflows via `jido_workflow`
- Execution behavior:
  - parse command markdown frontmatter into command definitions
  - parse workflow markdown into validated workflow definitions
  - execute through runtime engines:
    - `JidoCommand.Extensibility.CommandRuntime`
    - `JidoWorkflow.Workflow.Engine`
  - return structured runtime metadata under tool result:
    - command: `mode: :executed`, `runtime: :jido_command`
    - workflow: `mode: :executed`, `runtime: :jido_workflow`
- Compatibility behavior:
  - invalid/legacy command/workflow markdown assets degrade to preview mode rather than failing tool calls
  - preview fallback includes parse/validation reason context for operator debugging

### 22. Definition-aware tool schemas for LLM tool use

- Asset-backed tool specs now expose richer `input_schema` metadata when definitions are valid:
  - `command.run.*` schemas are derived from `jido_command` frontmatter `jido.schema` declarations
  - `workflow.run.*` schemas are derived from `jido_workflow` input declarations
- Schema behavior:
  - tool specs include typed top-level fields (for current runtime compatibility)
  - tool specs include nested `params`/`inputs` object schemas with required field hints
  - fallback remains permissive when definitions are invalid or unavailable
- This improves LLM/tool-call argument quality without introducing a second tool execution path.

### 23. Nested artifact guardrails + runtime override coverage

- Artifact guardrails now inspect nested result payloads for `artifacts` lists, including runtime bridge outputs:
  - command execution payloads (`execution.result.artifacts`)
  - workflow execution payloads with nested artifact collections
- Guardrail behavior:
  - `tool_max_artifact_bytes` applies across all discovered artifact entries, not just top-level tool result keys
  - failure reason remains deterministic: `{:artifact_too_large, index, size, max}`
- Runtime override coverage:
  - project-wide concurrency guardrail (`tool_max_concurrency`) is validated under concurrent `ToolRunner` load
  - operations runbook now documents runtime guardrail override knobs and verification steps.

## Evidence (Automated Tests)

- Added:
  - `test/jido_code_server/runtime_hardening_test.exs`
  - `test/jido_code_server/protocol_gateway_test.exs`
- Covered scenarios:
  - schema rejection
  - output cap enforcement
  - policy audit + telemetry events
  - correlation ID propagation through conversation + tool + policy paths
  - bounded incident timeline extraction (conversation + telemetry merge)
  - generated correlation ID fallback when ingest events omit one
  - sensitive artifact detection signal on risky tool outputs
  - sandbox violation security signal
  - allowlisted outside-root exception signal with reason code
  - conversation-scoped concurrency quota enforcement
  - deterministic `tool.cancelled` events on conversation cancellation
  - cancellable async tool bridge execution path
  - runtime option validation and normalization
  - environment passthrough deny-by-default with explicit allowlist control
  - sensitive path deny-by-default and explicit allowlist override
  - network deny-by-default and allowlist enforcement
  - nested network target extraction for allowlist/protocol enforcement
  - JSON-encoded endpoint payload enforcement for allowlist/protocol checks
  - JSON wrapper payload enforcement under non-network keys
  - opaque serialized payload endpoint/protocol enforcement
  - protocol deny-by-default with explicit allow override
  - configurable escalation alert routing from security/timeout telemetry signals
  - strict asset-loading startup failure mode with lenient fallback behavior
  - synthetic load/soak benchmark harness with structured report output
  - secret redaction behavior
  - repeated timeout escalation signal
  - timeout/cancellation child-process cleanup signal (`tool.child_processes_terminated`)
  - per-project protocol boundary enforcement across MCP/A2A adapters with security telemetry
  - command runtime execution via `jido_command` for valid command markdown and compatibility fallback for invalid definitions
  - workflow runtime execution via `jido_workflow` for valid workflow markdown and compatibility fallback for invalid definitions
  - definition-aware command/workflow tool input schemas exposed via `Runtime.list_tools/1`
  - nested artifact guardrails for command/workflow runtime bridge payloads
  - concurrent project-wide `tool_max_concurrency` guardrail enforcement coverage

## Residual Constraints

- Child-process termination controls require execution bridges to register spawned child processes; untracked external processes remain outside this guardrail.
- Opaque payload enforcement is heuristic-based and may miss deeply encoded or encrypted endpoint data.
- Benchmark harness is synthetic/in-process; production sign-off should still include environment-specific external load profiles.
