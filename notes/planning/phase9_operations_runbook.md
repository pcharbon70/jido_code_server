# Jido.Code.Server Phase 9 Operations Runbook

## Scope

- Runtime namespace: `Jido.Code.Server`
- Focus: project runtime health, tool execution safety, and incident triage
- Applies to: project supervisors, conversation runtime, policy/tool boundaries, watcher reload pipeline

## Daily Health Checks

1. Confirm runtime boots cleanly:
   - `mix ci`
   - project startup should reject malformed runtime options with `{:invalid_runtime_opt, key, reason}` instead of booting with unsafe defaults.
2. Verify project-level diagnostics are reachable:
   - `Jido.Code.Server.diagnostics(project_id)`
3. Verify telemetry counters are advancing:
   - `diagnostics.telemetry.event_counts`
4. Verify recent error queue is bounded and redacted:
   - `diagnostics.telemetry.recent_errors`

## Primary Signals and Alert Thresholds

### Tool execution

- `tool.failed`:
  - alert when sustained failure ratio exceeds 5% over 5 minutes.
  - if reason is `conversation_max_concurrency_reached`, treat as conversation-level saturation and tune `tool_max_concurrency_per_conversation` as needed.
  - if reason contains `invalid_tool_args`, inspect nested schema-path failures (`params.*`, `inputs.*`) and align caller payload shape with published tool `input_schema`.
- `tool.cancelled`:
  - expected after `conversation.cancel` when pending tool calls exist; alert only if cancellation volume is unexpectedly high.
  - async requests (`meta.run_mode = "async"`) should transition to `tool.completed`/`tool.failed` unless conversation cancellation occurs first.
- `tool.timeout`:
  - investigate immediately if timeout count spikes > 10 in 5 minutes for any project.
- `tool.child_processes_terminated`:
  - expected during timeout/cancel cleanup when tools spawn registered child processes.
  - investigate if frequent under normal load; indicates persistent long-running or stuck child execution.
- `security.repeated_timeout_failures`:
  - page on first occurrence per project; indicates repeated timeout threshold reached.

### Policy and sandboxing

- `policy.denied`:
  - expected for unauthorized calls; alert only on sudden volume spikes (>3x baseline).
- `security.sandbox_violation`:
  - page immediately; indicates outside-root path attempt.
  - include nested arguments and JSON wrapper payloads in triage (`payload.path`, nested lists/maps, and decoded JSON blobs).
- `security.sandbox_exception_used`:
  - warning by default; validate reason code and change ticket context for each occurrence.
- `security.sensitive_path_denied`:
  - page for unexpected access to denylisted sensitive files (investigate credential handling and tool prompts).
- `security.sensitive_artifact_detected`:
  - warning by default; investigate if frequent, since tool results are returning potentially sensitive content.
- `security.network_denied`:
  - warning by default; page if repeated and unexpected for a project with enabled egress policy.
  - includes endpoint-denied and protocol-denied (`network_protocol_denied`) policy outcomes.
  - evaluate nested payloads, JSON-encoded values, JSON wrapper fields, and opaque serialized blobs (`url`/`uri`/`host`/`domain`/`endpoint`) when triaging denials.
- `security.env_denied`:
  - warning by default; indicates disallowed or malformed `env` passthrough on command/workflow tools.
  - tune `tool_env_allowlist` only for explicitly approved environment variable keys.
- `security.protocol_denied`:
  - warning by default; indicates blocked MCP/A2A adapter access due project `protocol_allowlist`.
  - review payload context (`protocol`, `operation`) and update per-project `protocol_allowlist` only when exposure is intentional.

### Asset lifecycle

- `project.watcher_reload_failed`:
  - warning on first event, page if repeated 3 times in 10 minutes.
- `project.assets_reloaded` with non-zero `error_count`:
  - open incident ticket if persistent across 3 successive reloads.
- `strict_asset_loading`:
  - enable for fail-fast startup behavior when loader parse errors are present.
  - disable for degraded-but-available startup when parse errors should be tolerated temporarily.

## Alert Router Configuration

- Configure escalation routing with application env:
  - `alert_signal_events` - telemetry events to route to alerting
  - `alert_router` - callback target (`{module, function}` or `{module, function, extra_args}`)
- Default escalation events:
  - `security.sandbox_violation`
  - `security.repeated_timeout_failures`
- Router callback signature:
  - `(event_name, payload, metadata)` for `{module, function}`
  - `(event_name, payload, metadata, ...extra_args)` for `{module, function, extra_args}`

## Incident Response Playbook

1. Identify affected `project_id`, `conversation_id`, and `correlation_id` from telemetry payload.
2. Pull bounded timeline:
   - incident API: `Jido.Code.Server.incident_timeline(project_id, conversation_id, correlation_id: correlation_id, limit: 200)`
   - project diagnostics: `Jido.Code.Server.diagnostics(project_id)` for aggregate counters and health
3. Classify incident:
   - policy denial spike
   - sandbox violation
   - sandbox exception usage anomaly
   - repeated timeout failures
   - abnormal child-process termination volume
   - loader/watcher degradation
4. Apply containment:
   - stop high-error conversations with `Jido.Code.Server.stop_conversation/2`
   - if needed, stop affected project with `Jido.Code.Server.stop_project/1`
5. Recover:
   - fix invalid assets or runtime configuration
   - reload assets via `Jido.Code.Server.reload_assets/1`
   - restart project and verify diagnostics return to healthy baseline

## Failure Injection Commands (Pre-Release Validation)

1. Run full quality gate:
   - `mix ci`
2. Run Phase 9 reliability-focused tests:
   - `mix test test/jido_code_server/runtime_hardening_test.exs`
3. Stress/failure repeat:
   - `mix test test/jido_code_server/runtime_hardening_test.exs --repeat-until-failure 20`
4. Synthetic load/soak benchmark harness:
   - `mix phase9.bench`
   - tune profile as needed: `mix phase9.bench --projects 5 --conversations 8 --events 4 --concurrency 24`

## Escalation Criteria

- Immediate escalation:
  - any `security.sandbox_violation`
  - any `security.repeated_timeout_failures` across multiple projects
- Same-day escalation:
  - persistent watcher reload failures
  - repeated loader parse failures with degraded asset availability
