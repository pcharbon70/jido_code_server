# JidoCode Multi‑Project Coding Assistant Runtime — Module-by-Module Specification

This document specifies a **module-by-module architecture** for the JidoCode runtime, aligned to:

- **Project = container** (supervision boundary, shared assets, sandbox policy, tool runner)
- **Conversation = `JidoConversation` runtime instance** (event ingestion + projections)
- **Protocols/UIs = adapters** (translate external messages into conversation events and/or tool invocations)

---

## Naming conventions

- `project_id` — unique project instance identifier (ULID/UUID)
- `conversation_id` — unique conversation identifier (ULID/UUID)
- `root_path` — project filesystem sandbox root (absolute, realpath)
- `data_dir` — project data folder under root, default `.jido`

---

## Supervision overview

### Top-level application

- `JidoCode.Application`  
  - starts `JidoCode.Engine.Supervisor`

### Engine-level (multi-project)

- `JidoCode.Engine.Supervisor`
  - `JidoCode.Engine.ProjectRegistry` (Registry)
  - `JidoCode.Engine.ProjectSupervisor` (DynamicSupervisor)
  - `JidoCode.Engine.ProtocolSupervisor` (optional)

### Project-level (per project instance)

- `JidoCode.Project.Supervisor`
  - `JidoCode.Project.Server` (GenServer)
  - `JidoCode.Project.AssetStore` (GenServer + ETS owner)
  - `JidoCode.Project.Policy` (GenServer or pure module)
  - `JidoCode.Project.TaskSupervisor` (Task.Supervisor)
  - `JidoCode.Project.ConversationRegistry` (Registry)
  - `JidoCode.Project.ConversationSupervisor` (DynamicSupervisor)
  - `JidoCode.Project.Watcher` (optional)
  - `JidoCode.Project.ProtocolSupervisor` (optional per-project MCP/A2A)

---

# 1) Public facade

## `JidoCode`
**Summary:** Public API facade for assistants/frontends.

**Responsibilities**
- Provide stable entrypoints: start/stop projects, start/stop conversations
- Delegate to Engine/Project internals
- Keep protocol/UI code out of the core runtime

**Key functions**
- `start_project(root_path, opts) :: {:ok, project_id} | {:error, term}`
- `stop_project(project_id) :: :ok | {:error, term}`
- `list_projects() :: [%{project_id: ..., root_path: ...}]`
- `start_conversation(project_id, opts) :: {:ok, conversation_id} | {:error, term}`
- `stop_conversation(project_id, conversation_id) :: :ok | {:error, term}`
- `send_event(project_id, conversation_id, event) :: :ok | {:error, term}`
- `get_projection(project_id, conversation_id, key) :: {:ok, value} | {:error, term}`
- `list_tools(project_id) :: [tool_spec]`
- `reload_assets(project_id) :: :ok | {:error, term}`

**Notes**
- Events are generally delivered via `cast` (fire-and-forget); queries use `call`.

---

# 2) Engine modules (application-level, multi-project)

## `JidoCode.Engine.Supervisor`
**Summary:** Supervises global registries and the dynamic supervisor for projects.

**Responsibilities**
- Start global Registry and project DynamicSupervisor
- Ensure correct boot ordering

**Supervision child specs**
```elixir
children = [
  {Registry, keys: :unique, name: JidoCode.Engine.ProjectRegistry},
  {DynamicSupervisor, name: JidoCode.Engine.ProjectSupervisor, strategy: :one_for_one},
  JidoCode.Engine.ProtocolSupervisor # optional
]
Supervisor.start_link(children, strategy: :one_for_one, name: JidoCode.Engine.Supervisor)
```

---

## `JidoCode.Engine.ProjectRegistry`
**Summary:** `Registry` mapping `project_id -> project pid(s)`.

**Responsibilities**
- Fast lookup for any project instance by id
- Avoid global atom names

**Contract**
- Project supervisor or server registers:
  - key: `project_id`
  - value: metadata (root_path, data_dir, started_at, etc.)

---

## `JidoCode.Engine`
**Summary:** Internal Engine API used by the facade.

**Responsibilities**
- Start/stop project supervisors via `DynamicSupervisor`
- Provide lookup and listing helpers

**Key functions**
- `start_project(root_path, opts) -> {:ok, project_id, pid} | {:error, term}`
- `stop_project(project_id) -> :ok | {:error, term}`
- `whereis_project(project_id) -> {:ok, pid} | :error`
- `list_projects() -> [...]`

**Message contracts**
- Uses `DynamicSupervisor.start_child/2`
- Uses `Registry.lookup/2`

---

## `JidoCode.Engine.ProtocolSupervisor` (optional)
**Summary:** Hosts global protocol listeners (single-port multiplexers).

**Responsibilities**
- Run MCP/A2A gateways that multiplex by `project_id`
- Keep protocol lifecycle independent from core runtime

**Supervision child specs (example)**
```elixir
children = [
  {JidoCode.Protocol.MCP.Gateway, [engine: JidoCode.Engine]},
  {JidoCode.Protocol.A2A.Gateway, [engine: JidoCode.Engine]}
]
Supervisor.start_link(children, strategy: :one_for_one, name: JidoCode.Engine.ProtocolSupervisor)
```

---

# 3) Project modules (project-level container)

## `JidoCode.Project.Supervisor`
**Summary:** Per-project supervision boundary (isolation container).

**Responsibilities**
- Start project server, shared assets, policy, and execution supervisors
- Start conversation registry and conversation supervisor
- Optionally start watcher and per-project protocol endpoints

**Supervision child specs (template)**
```elixir
children = [
  {JidoCode.Project.Server, init},
  {JidoCode.Project.AssetStore, init},
  {JidoCode.Project.Policy, init},
  {Task.Supervisor, name: via(project_id, JidoCode.Project.TaskSupervisor)},
  {Registry, keys: :unique, name: via(project_id, JidoCode.Project.ConversationRegistry)},
  {DynamicSupervisor, name: via(project_id, JidoCode.Project.ConversationSupervisor), strategy: :one_for_one},
  {JidoCode.Project.Watcher, init} # optional
]
Supervisor.start_link(children, strategy: :one_for_one, name: via(project_id, JidoCode.Project.Supervisor))
```

> Prefer `via` (Registry/Horde) naming rather than atoms.

---

## `JidoCode.Project.Server`
**Summary:** Project “control plane” GenServer.

**Responsibilities**
- Own project configuration (root_path, data_dir, policy opts)
- Ensure on-disk layout exists
- Coordinate asset load/reload
- Start/stop conversations
- Route messages to conversations
- Provide policy-filtered tool inventory

**State**
- `%{project_id, root_path, data_dir, layout, asset_store, policy, conv_sup, conv_reg, task_sup}`

**Public calls/casts**
- `call {:start_conversation, opts} -> {:ok, conversation_id} | {:error, term}`
- `call {:stop_conversation, conversation_id} -> :ok | {:error, term}`
- `cast {:send_event, conversation_id, event} -> :ok`
- `call {:get_projection, conversation_id, key} -> {:ok, value} | {:error, term}`
- `call :list_tools -> [tool_spec]`
- `call :reload_assets -> :ok | {:error, term}`

---

## `JidoCode.Project.Layout`
**Summary:** Pure helpers for filesystem layout.

**Responsibilities**
- Compute `.jido`-based subpaths
- Ensure directory tree exists on project start
- Provide safe path helper utilities

**Key functions**
- `paths(root_path, data_dir) -> %{data: ..., skills: ..., commands: ..., workflows: ..., skill_graph: ..., state: ...}`
- `ensure_layout!(root_path, data_dir) -> layout_map`

---

## `JidoCode.Project.AssetStore`
**Summary:** ETS-backed store of compiled project assets (shared across conversations).

**Responsibilities**
- Load/compile assets from disk once per project
- Store compiled artifacts in ETS for fast reads
- Provide query APIs to conversations/adapters
- Support reload (manual or watcher-triggered)
- Emit signals for observability (recommended)

**State**
- `%{project_id, layout, ets, versions, loaders}`

**ETS key scheme**
- `{ :skill, name } -> %Skill{}`
- `{ :command, name } -> %Command{}`
- `{ :workflow, name } -> %Workflow{}`
- `{ :skill_graph, :snapshot } -> %Graph{}`

**Public calls**
- `call {:get, type, key} -> {:ok, value} | :error`
- `call {:list, type} -> [value]`
- `call :reload -> :ok | {:error, term}`
- `call {:search, type, query} -> [...]` (optional)

---

## `JidoCode.Project.Loaders.Skill`
**Summary:** Loads markdown skills from `.jido/skills`.

**Responsibilities**
- Discover skill files
- Parse + validate metadata
- Compile into runtime structs

**Contract**
- `load(layout) -> {:ok, [%Skill{}]} | {:error, term}`

---

## `JidoCode.Project.Loaders.Command`
**Summary:** Loads markdown slash commands from `.jido/commands`.

**Responsibilities**
- Discover command specs
- Parse + validate command metadata and patterns
- Compile to command descriptors usable by dispatch

**Contract**
- `load(layout) -> {:ok, [%Command{}]} | {:error, term}`

---

## `JidoCode.Project.Loaders.Workflow`
**Summary:** Loads workflows from `.jido/workflows`.

**Responsibilities**
- Discover workflow definitions
- Compile into executable workflow graphs (JidoWorkflow runtime)
- Provide runtime metadata

**Contract**
- `load(layout) -> {:ok, [%Workflow{}]} | {:error, term}`

---

## `JidoCode.Project.Loaders.SkillGraph`
**Summary:** Loads/builds skill graph snapshot from `.jido/skill_graph`.

**Responsibilities**
- Parse markdown nodes and wiki links
- Build graph snapshot for fast query
- Return snapshot object stored in ETS

**Contract**
- `load(layout) -> {:ok, graph_snapshot} | {:error, term}`

---

## `JidoCode.Project.Policy`
**Summary:** Project sandbox and authorization policy.

**Responsibilities**
- Enforce sandbox boundary under `root_path`
- Normalize paths and prevent traversal
- Apply tool allow/deny policy
- Filter tool lists for exposure to LLM/protocol adapters

**Key functions**
- `normalize_path(root, user_path) -> {:ok, safe_abs_path} | {:error, :outside_root}`
- `authorize_tool(tool_name, args, ctx) -> :ok | {:error, :denied}`
- `filter_tools(tool_specs) -> tool_specs`

**Recommended defaults**
- Require `realpath` resolution
- Disallow leaving sandbox even through symlinks unless explicitly allowed

---

## `JidoCode.Project.ToolCatalog`
**Summary:** Computes the tool inventory for a project.

**Responsibilities**
- Combine:
  - built-in safe tools (`JidoAction` modules)
  - tools derived from assets (commands/workflows/graph queries)
  - user-registered custom tools (optional extension point)
- Return tool specs suitable for LLM tool-use (name, description, schema)

**Key functions**
- `all_tools(project_ctx) -> [tool_spec]`
- `get_tool(project_ctx, name) -> {:ok, tool_spec} | :error`

---

## `JidoCode.Project.ToolRunner`
**Summary:** Single execution pathway for all tool calls in a project.

**Responsibilities**
- Validate tool call via `Project.Policy`
- Execute under `Project.TaskSupervisor` (timeouts, concurrency)
- Normalize results into structured tool result payloads
- Emit telemetry signals (tool started/completed/failed)

**Tool call format**
- `%{name: String.t(), args: map(), meta: %{conversation_id: ..., request_id: ...}}`

**Key functions**
- `run(project_ctx, tool_call) -> {:ok, result} | {:error, term}`
- `run_async(project_ctx, tool_call, reply_to: {pid, ref}) -> :ok`

**Result format**
- success: `%{ok: true, data: map() | binary(), artifacts: list(), logs: list()}`
- error: `%{ok: false, error: %{type: atom() | String.t(), message: String.t(), details: map()}}`

---

## `JidoCode.Project.Watcher` (optional)
**Summary:** File watcher for `.jido/*` that triggers asset reload.

**Responsibilities**
- Watch `.jido/skills`, `.jido/commands`, `.jido/workflows`, `.jido/skill_graph`
- Debounce bursts
- Call `AssetStore.reload/0`
- Emit `assets.changed` signals

---

## `JidoCode.Project.ConversationRegistry`
**Summary:** Project-local registry mapping `conversation_id -> conversation pid`.

**Responsibilities**
- Provide lookup for routing events/projection reads

---

## `JidoCode.Project.ConversationSupervisor`
**Summary:** Project-local DynamicSupervisor for conversation servers.

**Responsibilities**
- Start and restart conversations independently
- Typically `:transient` restart for conversation processes

**Child spec**
- `{JidoCode.Conversation.Server, %{project_id: ..., conversation_id: ..., opts: ...}}`

---

# 4) Conversation modules (conversation = `JidoConversation` runtime)

## `JidoCode.Conversation.Server`
**Summary:** Thin GenServer wrapper around a `JidoConversation` instance.

**Responsibilities**
- Hold `JidoConversation.t()` as state
- Ingest inbound events
- Expose projections (`llm_context`, timeline, diagnostics, etc.)
- Notify subscribers (UI/protocol adapters)
- Delegate “next step” decisions to `Conversation.Loop`

**State**
- `%{project_id, conversation_id, conversation, subscribers, projection_cache}`

**Public API**
- `cast {:event, event}`
- `call {:get_projection, key} -> {:ok, value} | {:error, term}`
- `call {:subscribe, pid} -> :ok`
- `call {:unsubscribe, pid} -> :ok`

**Outbound notifications**
- `{:conversation_event, conversation_id, event}`
- `{:conversation_delta, conversation_id, delta}` (optional convenience)

---

## `JidoCode.Conversation.Loop`
**Summary:** Pure decision logic triggered after each ingest.

**Responsibilities**
- After ingest, decide whether to:
  - start an LLM call
  - request tool execution
  - emit final assistant message
- Keep orchestration consistent with projections produced by `JidoConversation`

**Contract**
- `after_ingest(conv_state, project_ctx) -> {:ok, conv_state, emitted_events}`

---

## `JidoCode.Conversation.LLM`
**Summary:** Adapter around `JidoAi` for LLM calls (streaming and tool-use).

**Responsibilities**
- Build request from `:llm_context` projection
- Attach tool specs (policy-filtered) when tool-use enabled
- Convert streaming deltas to conversation events
- Convert tool-call intents to `tool.requested` events

**Key functions**
- `start_completion(project_ctx, conversation_id, llm_context, opts) -> {:ok, ref} | {:error, term}`
- `cancel(ref) -> :ok`

---

## `JidoCode.Conversation.ToolBridge`
**Summary:** Bridges tool-request events to Project tool execution and returns tool result events.

**Responsibilities**
- When `tool.requested` event is emitted:
  - call `Project.ToolRunner.run/2` (sync) or async variant
  - emit `tool.completed` or `tool.failed` back into the conversation

**Contract**
- `handle_tool_requested(project_ctx, conversation_id, tool_call) -> :ok`

Implementation choices:
- helper module invoked by `Conversation.Server`, **or**
- dedicated per-conversation bridge process (optional isolation)

---

# 5) Protocol adapters (MCP, A2A) as event adapters

## `JidoCode.Protocol.MCP.Gateway` (optional, global)
**Summary:** Global MCP server multiplexing requests by `project_id`.

**Responsibilities**
- `tools/list` -> call `Project.Server.list_tools/0`
- `tools/call` -> call `Project.ToolRunner.run/2` (policy enforced)
- optional “chat” mapping -> inject `user.message` events into conversations

**Inbound mapping**
- MCP request -> internal call:
  - `{:mcp_list_tools, project_id}`
  - `{:mcp_call_tool, project_id, tool_call}`
  - `{:mcp_send_message, project_id, conversation_id, content}`

---

## `JidoCode.Protocol.MCP.ProjectServer` (optional, per-project)
**Summary:** Per-project MCP server (no multiplexing).

**Responsibilities**
- Same as gateway but dedicated to one project instance
- Easier isolation at the cost of multiple listeners

---

## `JidoCode.Protocol.A2A.Gateway` (optional, global)
**Summary:** A2A endpoint exposing projects as agent hosts and conversations as sessions.

**Responsibilities**
- Serve agent card derived from:
  - policy-filtered tool list
  - commands/workflows/skills summaries
- Map A2A tasks/messages to conversation events
- Stream progress by subscribing to conversation events or signals

**Inbound mapping**
- `task.create` -> start conversation + inject `user.message`
- `message.send` -> inject `user.message`
- `task.cancel` -> inject `conversation.cancel` event

---

# 6) Signals and telemetry

## `JidoCode.Telemetry`
**Summary:** Centralizes emission of `JidoSignal` events.

**Responsibilities**
- Standardize event names + payload shapes
- Allow UIs/adapters to subscribe without coupling

**Suggested signals**
- `project.started`, `project.stopped`
- `project.assets_loaded`, `project.assets_reloaded`
- `conversation.started`, `conversation.stopped`
- `conversation.event_ingested`
- `llm.started`, `llm.delta`, `llm.completed`, `llm.failed`
- `tool.started`, `tool.completed`, `tool.failed`

---

# 7) Recommended types

## `JidoCode.Types.Event`
- `%{type: String.t(), at: DateTime.t(), data: map(), meta: map()}`

## `JidoCode.Types.ToolSpec`
- `%{name: String.t(), description: String.t(), input_schema: map(), output_schema: map(), safety: map()}`

## `JidoCode.Types.ToolCall`
- `%{name: String.t(), args: map(), meta: map()}`

---

# Appendix: Project data directory layout

```text
<root>/
  .jido/
    skills/
    commands/
    workflows/
    skill_graph/
    state/
```
