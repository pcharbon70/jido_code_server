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

### 6. Network egress policy controls

- Tool metadata now marks network-capable tools (`command.run.*`, `workflow.run.*`) in `ToolCatalog`.
- Policy enforces network egress controls:
  - default deny (`network_egress_policy: :deny`)
  - explicit enable (`:allow`)
  - optional `network_allowlist` endpoint/domain filtering when enabled
  - protocol allowlist guardrail via `network_allowed_schemes` (default `["http", "https"]`)
- Disallowed protocols are denied with:
  - `:network_protocol_denied`
- Policy telemetry now emits security signal on denied network attempts:
  - `security.network_denied`

### 7. Correlation ID propagation across runtime boundaries

- Conversation ingest now guarantees a correlation ID on every incoming event and propagates it to emitted events.
- LLM lifecycle events (`llm.started`, `assistant.delta`, `tool.requested`, `assistant.message`, `llm.completed`) carry the same correlation ID.
- Tool bridge and tool runner propagate correlation ID through:
  - tool call metadata
  - tool response payloads (`tool.completed`, `tool.failed`, timeout/escalation telemetry)
  - policy decision records (`recent_decisions`, `policy.allowed`, `policy.denied`)
- This enables end-to-end incident stitching by `project_id` + `conversation_id` + `correlation_id`.

### 8. Incident timeline extraction for response workflows

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

## Evidence (Automated Tests)

- Added: `test/jido_code_server/project_phase9_test.exs`
- Covered scenarios:
  - schema rejection
  - output cap enforcement
  - policy audit + telemetry events
  - correlation ID propagation through conversation + tool + policy paths
  - bounded incident timeline extraction (conversation + telemetry merge)
  - generated correlation ID fallback when ingest events omit one
  - sandbox violation security signal
  - network deny-by-default and allowlist enforcement
  - protocol deny-by-default with explicit allow override
  - secret redaction behavior
  - repeated timeout escalation signal

## Residual Constraints

- Tool timeout handling currently terminates the task process; child OS process group termination is not yet implemented.
- Network allowlist enforcement depends on tool argument metadata (`url`/`host`/`domain`/`endpoint`) and is advisory for opaque command/workflow payloads.
- External benchmark harness beyond test-suite load scenarios remains pending for full operational sign-off.
