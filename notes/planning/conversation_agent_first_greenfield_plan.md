# Conversation Agent-First Greenfield Plan

This document locks the implementation direction for the signal-first conversation runtime.

## Locked Decisions

1. Conversation execution runtime is `Jido.AgentServer` only.
2. Canonical conversation envelope is `Jido.Signal`.
3. Tool execution remains centralized through `Project.Policy -> Project.ExecutionRunner`.
4. Sub-agent spawning is template-gated (`agent.spawn.<template_id>`), not free-form.
5. Runtime APIs are agent-first (`conversation_call`, `conversation_cast`, `conversation_state`, `conversation_projection`).

## Runtime Constants

- `max_queue_size`: 10_000
- `max_drain_steps`: 128
- `default_subagent_max_children`: 3
- `default_subagent_ttl_ms`: 300_000

## Signal Catalog

- `conversation.user.message`
- `conversation.assistant.delta`
- `conversation.assistant.message`
- `conversation.llm.requested`
- `conversation.llm.completed`
- `conversation.llm.failed`
- `conversation.tool.requested`
- `conversation.tool.completed`
- `conversation.tool.failed`
- `conversation.cancel`
- `conversation.resume`
- `conversation.subagent.requested`
- `conversation.subagent.started`
- `conversation.subagent.completed`
- `conversation.subagent.failed`
- `conversation.subagent.stopped`
- `conversation.queue.overflow`
