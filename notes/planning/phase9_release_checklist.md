# JidoCodeServer Phase 9 Release Checklist

## Quality Gates

- [ ] `mix ci` passes on the release branch.
- [ ] `test/jido_code_server/project_phase9_test.exs` passes.
- [ ] No open P0/P1 correctness or security defects.

## Security Gates

- [ ] Tool schema validation rejects malformed payloads.
- [ ] Policy decisions emit `policy.allowed` / `policy.denied` with auditable context.
- [ ] Sandbox escape attempts emit `security.sandbox_violation`.
- [ ] Telemetry redaction masks secret/token patterns in recent errors.
- [ ] Repeated timeout escalation emits `security.repeated_timeout_failures`.

## Reliability Gates

- [ ] Loader parse failure paths are tested and non-crashing.
- [ ] LLM adapter failure path emits `llm.failed` and keeps conversation runtime available.
- [ ] Watcher storm behavior remains debounced and stable.
- [ ] Multi-project concurrent conversation workload validates isolation.

## Operational Readiness

- [ ] Runbook is current: `notes/planning/phase9_operations_runbook.md`.
- [ ] Hardening report is current: `notes/planning/phase9_hardening_report.md`.
- [ ] Runtime guardrail overrides (`tool_timeout_ms`, `tool_max_output_bytes`, etc.) are documented and test-covered.
- [ ] Alert routing is configured for security and timeout escalation signals.

## Sign-Off

- [ ] Engineering sign-off
- [ ] Security sign-off
- [ ] Operations/on-call sign-off

