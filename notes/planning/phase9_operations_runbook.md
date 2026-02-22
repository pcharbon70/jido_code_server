# Jido.Code.Server Phase 9 Operations Runbook

## Scope

- Runtime namespace: `Jido.Code.Server`
- Focus: project runtime health, tool execution safety, and incident triage
- Applies to: project supervisors, conversation runtime, policy/tool boundaries, watcher reload pipeline

## Daily Health Checks

1. Confirm runtime boots cleanly:
   - `mix ci`
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
- `tool.timeout`:
  - investigate immediately if timeout count spikes > 10 in 5 minutes for any project.
- `security.repeated_timeout_failures`:
  - page on first occurrence per project; indicates repeated timeout threshold reached.

### Policy and sandboxing

- `policy.denied`:
  - expected for unauthorized calls; alert only on sudden volume spikes (>3x baseline).
- `security.sandbox_violation`:
  - page immediately; indicates outside-root path attempt.
- `security.network_denied`:
  - warning by default; page if repeated and unexpected for a project with enabled egress policy.
  - includes endpoint-denied and protocol-denied (`network_protocol_denied`) policy outcomes.

### Asset lifecycle

- `project.watcher_reload_failed`:
  - warning on first event, page if repeated 3 times in 10 minutes.
- `project.assets_reloaded` with non-zero `error_count`:
  - open incident ticket if persistent across 3 successive reloads.

## Incident Response Playbook

1. Identify affected `project_id`, `conversation_id`, and `correlation_id` from telemetry payload.
2. Pull bounded timeline:
   - incident API: `Jido.Code.Server.incident_timeline(project_id, conversation_id, correlation_id: correlation_id, limit: 200)`
   - project diagnostics: `Jido.Code.Server.diagnostics(project_id)` for aggregate counters and health
3. Classify incident:
   - policy denial spike
   - sandbox violation
   - repeated timeout failures
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
   - `mix test test/jido_code_server/project_phase9_test.exs`
3. Stress/failure repeat:
   - `mix test test/jido_code_server/project_phase9_test.exs --repeat-until-failure 20`

## Escalation Criteria

- Immediate escalation:
  - any `security.sandbox_violation`
  - any `security.repeated_timeout_failures` across multiple projects
- Same-day escalation:
  - persistent watcher reload failures
  - repeated loader parse failures with degraded asset availability
