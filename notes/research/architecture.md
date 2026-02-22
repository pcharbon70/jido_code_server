# JidoCode Multi‑Project Coding Assistant Runtime — Tight Alignment Rewrite

This document rewrites the proposed architecture so it aligns tightly with the existing Jido ecosystem work:

- **Project = supervisor tree + shared asset store + sandbox/tool policy**
- **Conversation = a `JidoConversation` runtime instance** (event ingestion + projections)
- Everything else (UI, MCP, A2A, slash commands, workflows) is an **adapter that emits events into a conversation** and uses the same **project‑scoped tool runner**.

---

## Design stance

1. **`JidoConversation` is the canonical runtime for “a conversation”.**  
   It owns:
   - the event log / timeline
   - projections (LLM context, state, diagnostics)
   - progression rules (what happens when an event arrives)

2. **A Project is a container** that provides:
   - filesystem root sandbox and tool policy
   - shared, preloaded assets (skills/commands/workflows/skill graph)
   - a conversation supervisor (parallel conversations)
   - a single consistent tool execution pathway

3. **All integrations are protocol/UI adapters**
   - MCP, A2A, LiveView, CLI: all convert inbound messages into `JidoConversation` events
   - tool calls always go through the same project tool runner

---

## OTP supervision topology

### Application level: hosts many isolated projects

```text
JidoCode.Engine.Supervisor
├─ JidoCode.Engine.ProjectRegistry     (Registry: project_instance_id -> pid)
├─ JidoCode.Engine.ProjectSupervisor   (DynamicSupervisor: starts projects)
└─ JidoCode.Engine.ProtocolSupervisor  (optional: global listeners / multiplexers)
```

### Project level: hosts shared assets + many parallel conversations

```text
JidoCode.Project.Supervisor (one per project instance)
├─ JidoCode.Project.Server            (GenServer: config, lifecycle, routing)
├─ JidoCode.Project.AssetStore        (ETS + GenServer: skills/commands/workflows/graph)
├─ JidoCode.Project.Policy            (GenServer: sandbox + tool allowlists)
├─ JidoCode.Project.ToolRunner        (module + Task.Supervisor child)
├─ JidoCode.Project.TaskSupervisor    (Task.Supervisor: tool exec + timeouts)
├─ JidoCode.Project.ConversationReg   (Registry: conversation_id -> pid)
└─ JidoCode.Project.ConversationSup   (DynamicSupervisor: conversations)
```

---

## Project instance model

A **project instance** is identified by a `project_instance_id` and bound to:
- `root_path` (filesystem sandbox root)
- `data_dir` (default `.jido`, configurable)
- `asset snapshot` (loaded once, shared across all conversations)
- `tool policy` (default: deny outside `root_path`)

Multiple instances may point to the *same* root (e.g., different policies/configs), but by default they’re isolated at runtime by separate supervisors + registries.

---

## Filesystem layout and asset loading

### Default on‑disk structure

```text
<root>/
  .jido/
    skills/
    commands/
    workflows/
    skill_graph/
    state/        (optional: traces, caches, exported artifacts)
```

### Loading strategy (project boot)

On project start:
1. Canonicalize `root_path` (realpath; guard symlink escapes)
2. Ensure `.jido` + subdirs exist
3. Load and compile:
   - `JidoSkill` markdown → compiled skill entries
   - `JidoCommand` markdown → slash command definitions + dispatch metadata
   - `JidoWorkflow` definitions → executable workflow graphs
   - `JidoSkillGraph` markdown set → in‑memory graph snapshot
4. Store the compiled results in **project‑local ETS** via `Project.AssetStore`

**Key alignment point:** conversations never “own” assets; they query `AssetStore` read‑only.

---

## Conversation runtime = `JidoConversation` + a thin OTP wrapper

### One process per conversation

Each conversation process is a thin wrapper around a `JidoConversation` instance:

- It receives inbound events (`user.message`, `tool.requested`, `tool.completed`, etc.)
- It calls `JidoConversation.ingest(conversation, event)`
- It publishes any resulting outbound events (deltas, tool requests, notifications)

A practical shape:

```text
JidoCode.Conversation.Server (GenServer)
- state: %{conversation: JidoConversation.t(), project_id: ..., conversation_id: ...}
- handle_cast({:event, e}, state) -> ingest -> emit follow-up events
```

**Why this is tight to your work:** the GenServer does not implement conversation logic; it delegates to `JidoConversation` for event handling and projections.

---

## Event flow

This is the “spine”:

1) **Inbound adapter** (UI/MCP/A2A/CLI) sends a `user.message` event to the conversation  
2) Conversation ingests → projection yields next step:
- maybe “call LLM”
- maybe “request tool”
- maybe “emit assistant output”

3) If a tool is requested:
- Conversation emits `tool.requested`
- Project’s `ToolRunner` executes it (sandboxed)
- Tool result is returned as `tool.completed` or `tool.failed`
- Conversation ingests result and continues

**Single source of truth:** the conversation’s state is a pure function of its applied events.

---

## Tooling aligned to JidoAction + JidoAi

### Tools should be `JidoAction` modules

- Define strict schemas (paths, commands, options)
- Use `JidoAction` introspection to expose tool signatures to LLMs
- Use `JidoAi` for LLM calls and tool‑use orchestration as needed

### Tool sandboxing lives at the Project layer

**All tool calls go through:**
`JidoCode.Project.Policy.validate(tool_call, project_root)`  
then execute via:
`JidoCode.Project.ToolRunner.run(action, args, ctx)`

Default policy rules:
- any filesystem path arg is resolved under `project_root`
- working directory = `project_root`
- timeouts + concurrency limits enforced by the project `TaskSupervisor`
- explicit escape hatches must be allowlisted per project instance

This keeps the “safe by default” guarantee independent of UI/protocol.

---

## Shared assets usage in conversations

Conversations can:
- query skills/commands/workflows/graph from `Project.AssetStore`
- include summaries/topography in LLM context (selectively)
- execute:
  - slash commands via `JidoCommand` dispatch
  - workflows via `JidoWorkflow` engine
  - graph queries via `JidoSkillGraph` APIs

But the execution path still goes through:
- conversation event → project tool runner → tool result event

So commands/workflows are *not* a separate execution universe; they’re just structured event producers.

---

## JidoSignal as the observability + coordination backbone

Use `JidoSignal` for:
- project lifecycle events (`project.started`, `project.assets_loaded`)
- conversation telemetry (`conversation.event_ingested`, `conversation.llm_call_started`)
- tool telemetry (`tool.started`, `tool.completed`, `tool.failed`)
- optional streaming to external adapters (SSE/WebSocket/MCP notifications)

This lets UIs and protocol servers subscribe without coupling to internal processes.

---

## Protocols as adapters, not alternate runtimes

### MCP adapter

An MCP server:
- lists tools by asking the **project** what is allowed/exposed (policy + actions)
- invokes tools by calling the **project** tool runner
- optionally interacts with conversations by emitting `user.message` events (or “tool‑only” mode)

### A2A adapter

An A2A server:
- presents each **project instance** as an agent host (capabilities derived from assets + tool list)
- maps A2A tasks/messages into conversation events
- streams progress by subscribing to `JidoSignal` events from that project/conversation

**Key alignment:** neither protocol owns state; conversations do.

---

## Minimal embedding API

At the “engine” boundary:

- `start_project(root_path, opts) -> project_instance_id`
- `stop_project(project_instance_id)`
- `start_conversation(project_instance_id, opts) -> conversation_id`
- `send_event(project_instance_id, conversation_id, event)`
- `get_projection(project_instance_id, conversation_id, projection_key)` (LLM context, timeline, etc.)
- `list_tools(project_instance_id)` (already policy‑filtered)
- `reload_assets(project_instance_id)` (optional, or via watcher)

Everything else (UI, MCP, A2A) builds on those primitives.
