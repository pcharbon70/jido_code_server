# Testing and Quality

This guide maps the test suite and quality gates used for runtime changes.

## Standard Commands

- `mix ci`
  - format check, compile warnings-as-errors, credo, test
- `mix quality` or `mix q`
  - `mix ci` plus dialyzer
- `mix test test/jido_code_server/runtime_hardening_test.exs`
  - focused hardening/security regression suite

## Test Suite Areas

- Engine/project lifecycle:
  - `test/jido_code_server/engine_test.exs`
- Conversation and orchestration:
  - `test/jido_code_server/conversation_orchestration_test.exs`
- Tool execution and policy:
  - `test/jido_code_server/tool_runtime_policy_test.exs`
- Security hardening and runtime guardrails:
  - `test/jido_code_server/runtime_hardening_test.exs`
- Protocol boundaries:
  - `test/jido_code_server/protocol_gateway_test.exs`
- Alert routing and telemetry:
  - `test/jido_code_server/alert_router_test.exs`
- Bench harness behavior:
  - `test/jido_code_server/benchmark_harness_test.exs`

## Change Validation Pattern

For architecture-level changes:

1. Run targeted tests for touched area.
2. Run `mix ci`.
3. If touching policy/tool runtime internals, run hardening tests explicitly.
4. If touching runtime options, add invalid/valid startup cases.

## Recommended PR Checklist

- Updated tests for behavior and regression risk.
- Updated docs under `docs/developer` for changed architecture contracts.
- Updated planning docs when a new hardening control is introduced.
- Verified no bypass path was introduced around `Policy` and `ToolRunner`.

> Security Aside
> 
> Any change that alters authorization, path handling, egress filtering, or runtime guardrails should include a negative test (expected denial) and a positive allowlist test.
