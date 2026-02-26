# 11. Testing and Quality

Prev: [10. Observability and Operations](./10-observability-and-operations.md)  
Next: `None`

## Test Strategy

The test suite is behavior-driven around runtime contracts.

Core test areas under `test/jido_code_server`:

- Engine lifecycle and option validation
- Asset loading/reload and strict mode behavior
- Conversation projection determinism and subscriptions
- Orchestration loop behavior (LLM, tool request, cancel/resume)
- Tool runtime policy enforcement and schema handling
- Security hardening (path, env, network, redaction, timeout escalation)
- Sub-agent policy and lifecycle
- Protocol gateways and allowlist enforcement
- Tool action bridge integration with Jido.AI tool calling context

## Quality Gates

From `README.md` quality commands:

- `mix ci`: format, compile warnings as errors, credo, tests
- `mix quality` / `mix q`: CI checks plus dialyzer

## Benchmark Coverage

`mix phase9.bench` runs synthetic load/soak scenarios to validate throughput and isolation behavior.

## Design Validation Themes

The current suite explicitly validates:

- deterministic signal and projection behavior
- policy-first execution path for all tools
- no project cross-talk under concurrent load
- cancellation cleanup of async tools and child processes
- reproducible incident/telemetry observability

## Recommended Extensions

1. Add property tests for reducer queue and dedupe invariants.
2. Add fault-injection tests around sub-agent crashes under heavy orchestration.
3. Add protocol fuzz tests for malformed payload normalization.
