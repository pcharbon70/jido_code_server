# 05. Conversation Runtime

Prev: [04. Assets and Project State](./04-assets-and-project-state.md)  
Next: [06. LLM and Tool Execution](./06-llm-and-tool-execution.md)

## Runtime Model

Each conversation runs as `Jido.Code.Server.Conversation.Agent` (a `Jido.Agent` on `Jido.AgentServer`).

State includes:

- `domain` (`Conversation.Domain.State`)
- `project_ctx` (tool, policy, LLM, sub-agent references)
- stable identifiers (`project_id`, `conversation_id`)

## Canonical Signal Path

1. API receives `%Jido.Signal{}`.
2. `Conversation.Agent.call/3` wraps it as `conversation.cmd.ingest`.
3. `IngestSignalAction` normalizes and enqueues.
4. `Reducer.drain_once/1` applies queued signals deterministically.
5. Effect intents map to directives.
6. Instruction results are re-ingested as canonical conversation signals.

## Domain State and Reducer

`Conversation.Domain.State` tracks:

- `timeline` (applied signals)
- `event_queue` and `queue_size`
- `pending_tool_calls`
- `pending_subagents`
- `correlation_index`
- `projection_cache`
- queue/drain limits and orchestration flag

Reducer guarantees:

- Dedup by `{signal.id, correlation_id}`
- Overflow emits `conversation.queue.overflow`
- Max drain steps produce `continue_drain` intent
- Deterministic projection recomputation

## Directive Boundary

Side effects are not executed in the reducer. Intents are mapped to directives:

- `run_llm` -> `RunLLMInstruction`
- `run_tool` -> `RunToolInstruction`
- `cancel_pending_tools` -> `CancelPendingToolsInstruction`
- `cancel_pending_subagents` -> `CancelSubagentsInstruction`

```mermaid
flowchart TD
    Ingest[Ingest signal] --> Queue[Reducer enqueue]
    Queue --> Drain[Reducer drain]
    Drain --> Intent[Effect intents]
    Intent --> Dir[Directives]
    Dir --> Instr[Instruction execution]
    Instr --> Result[Instruction result signal]
    Result --> Queue
```

## Projections

Built by `Conversation.Domain.Projections`:

- `timeline`
- `llm_context`
- `diagnostics`
- `subagent_status`
- `pending_tool_calls`

## Cancel and Resume

- `conversation.cancel` marks status cancelled and emits cancellation intents.
- Non-resume signals do not trigger orchestration while cancelled.
- `conversation.resume` returns state to `:idle` and normal flow can continue.

## Subscriber Model

`Project.Server` supports subscriber pids per conversation. After each call/tool-ingest update, new timeline entries are delivered as `{:conversation_event, ...}` and assistant deltas as `{:conversation_delta, ...}`.

## Security Aside

Correlation IDs are ensured at signal normalization boundaries and propagated through the entire conversation lifecycle, supporting incident forensics.
