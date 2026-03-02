# 13. Release Governance and Readiness

Prev: [12. Mode and Strategy Extension Model](./12-mode-and-strategy-extension-model.md)  
Next: `None`

## Release Candidate Checklist

Before tagging a release candidate:

1. Cross-repo contract fixtures pass in both repositories.
2. Mode orchestration integration tests pass for `:coding`, `:planning`, and
   `:engineering`.
3. Cancellation/resume and restart parity suites are green.
4. Docs and migration notes are synchronized across both repos.
5. No open blocker incidents in policy, execution, or journal replay paths.

## Core SLO Metrics

Track these at minimum per project and mode:

1. Strategy latency:
   - p95 and p99 from `conversation.execution.started` to
     `conversation.execution.completed` (`execution_kind = strategy_run`)
2. Tool latency:
   - p95 and p99 from `conversation.tool.started` to terminal tool event
3. Cancellation success:
   - ratio of `conversation.cancel` requests that end with drained pending work
     and successful `conversation.resume` continuity

## Alert Thresholds

Suggested initial thresholds:

1. Strategy latency:
   - page on p99 > 12s for 10 minutes
2. Tool latency:
   - page on p99 > 8s for 10 minutes for non-network tools
3. Cancellation success:
   - page when success ratio < 99.0% over rolling 30 minutes
4. Contract drift:
   - fail release gate immediately on fixture mismatch in either repo

## Incident Triage Signals

Prioritize correlation through:

1. `correlation_id`
2. `run_id`
3. `step_id`
4. `execution_id`

Triage order:

1. `incident_timeline/3` for conversation scope
2. policy decision telemetry (`allow`/`deny`) around the same correlation
3. canonical timeline and llm-context projections for replay parity checks

## Post-Release Validation Window

Use a fixed validation window after each release:

- Duration: 7 days
- Success criteria:
  - no Severity-1 regressions
  - SLOs within budget
  - no unresolved contract drift incidents
  - replay parity checks remain stable on sampled production traces

If criteria are not met, freeze feature rollout and execute rollback/mitigation
playbook from the cross-repo governance docs.
