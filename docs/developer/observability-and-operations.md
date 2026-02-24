# Observability and Operations

This guide covers telemetry, diagnostics, incident response APIs, and benchmark tooling.

## Telemetry Model

`lib/jido_code_server/telemetry.ex` provides:

- `emit/2` for event emission
- bounded counters by project
- bounded recent errors/events queues
- payload sanitization and secret redaction
- alert signal forwarding to `AlertRouter`

## Runtime Diagnostics APIs

Use the runtime facade in `lib/jido_code_server.ex`:

- `diagnostics(project_id)`
- `assets_diagnostics(project_id)`
- `conversation_diagnostics(project_id, conversation_id)`
- `incident_timeline(project_id, conversation_id, opts)`

`incident_timeline/3` merges conversation timeline events and telemetry events with optional correlation filtering.

## Alert Routing

`lib/jido_code_server/alert_router.ex` can forward selected telemetry signals to external handlers.

Key config entries:

- `:alert_signal_events`
- `:alert_router` (`{module, function}` or `{module, function, extra_args}`)

Defaults include critical security timeout/sandbox signals.

## Operational Runbook Inputs

For release and on-call guidance, use:

- `notes/planning/phase9_operations_runbook.md`
- `notes/planning/phase9_release_checklist.md`
- `notes/planning/phase9_hardening_report.md`

## Synthetic Benchmark Harness

`lib/jido_code_server/benchmark/phase9_harness.ex` provides a repeatable in-process workload harness.

Run with:

- `mix phase9.bench`

The report includes:

- project/conversation startup success
- event dispatch latency summary
- projection integrity checks
- consolidated failures

> Security Aside
> 
> Telemetry payload redaction is part of the security boundary. Do not bypass `Telemetry.emit/2` with ad hoc logging for sensitive runtime paths.
