# ADR 0002: Conversation Agent-First Runtime

- Status: Accepted
- Date: 2026-02-25

## Context

The runtime previously used a custom event-loop conversation server. We need a single, native Jido lifecycle model and explicit effect handling boundaries.

## Decision

1. Use `Jido.AgentServer` as the only conversation execution runtime.
2. Use `Jido.Signal` as canonical conversation input/output.
3. Keep the single tool execution path: `Project.Policy` followed by `Project.ExecutionRunner`.
4. Enable sub-agent spawning only through policy-gated templates exposed as tools.

## Consequences

- Conversation state transitions are pure action logic; side-effects are directive-driven.
- Tool and LLM effects are explicit runtime instructions.
- Correlation and telemetry stay consistent across parent and child agent lifecycles.
