# Jido.Code.Server Developer Guides

This directory documents the implementation architecture of `Jido.Code.Server`.

## Audience

These guides are for engineers working on runtime internals, adapters, and production hardening.

## Guide Map

- `architecture-overview.md`
  - System shape, supervision tree, and module boundaries.
- `engine-and-project-lifecycle.md`
  - Project startup/shutdown, runtime options, layout, asset lifecycle.
- `conversation-runtime.md`
  - Event model, orchestration loop, LLM and tool bridging behavior.
- `tool-execution-and-policy.md`
  - Tool catalog, policy gate, runner pipeline, execution backends.
- `security-model.md`
  - Built-in security controls, threat-to-control mapping, and secure override guidance.
- `protocol-adapters.md`
  - MCP and A2A adapter mappings and boundary controls.
- `observability-and-operations.md`
  - Telemetry, diagnostics, incident timeline, alert routing, and benchmark usage.
- `testing-and-quality.md`
  - Test suite map, quality gates, and change-validation patterns.

## Suggested Reading Order

1. `architecture-overview.md`
2. `engine-and-project-lifecycle.md`
3. `conversation-runtime.md`
4. `tool-execution-and-policy.md`
5. `security-model.md`
6. Remaining guides by concern area.
