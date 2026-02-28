# Jido.Code.Server

Elixir runtime for project-scoped coding assistance built on the Jido ecosystem.

## What It Provides

`Jido.Code.Server` runs many isolated projects in one runtime. Each project owns:

- policy and sandbox enforcement
- asset loading (`skills`, `commands`, `workflows`, `skill_graph`)
- conversation agents (`Jido.AgentServer`)
- policy-gated tool execution
- optional protocol access (MCP/A2A)
- telemetry and incident diagnostics

## Runtime Highlights

- Agent-first conversation runtime (`Jido.Code.Server.Conversation.Agent`)
- Signal-first conversation contract (`Jido.Signal`)
- Single execution core for tools (`Project.ToolRunner` + `Project.Policy`)
- Template-gated sub-agent spawning (`agent.spawn.<template_id>`)
- Canonical conversation journaling through `jido_conversation`

## Public API

The public facade is `Jido.Code.Server` (`/Users/Pascal/code/agentjido/jido_code_server/lib/jido_code_server.ex`).

Project lifecycle:

- `start_project/2`
- `stop_project/1`
- `list_projects/0`

Conversation lifecycle and interaction:

- `start_conversation/2`
- `stop_conversation/2`
- `conversation_call/4`
- `conversation_cast/3`
- `conversation_state/3`
- `conversation_projection/4`
- `subscribe_conversation/3`
- `unsubscribe_conversation/3`

Tools and assets:

- `list_tools/1`
- `run_tool/2`
- `reload_assets/1`
- `list_assets/2`
- `get_asset/3`
- `search_assets/3`

Diagnostics:

- `assets_diagnostics/1`
- `conversation_diagnostics/2`
- `incident_timeline/3`
- `diagnostics/1`

## Developer Guides

Architecture guides live in:

- `/Users/Pascal/code/agentjido/jido_code_server/docs/developer/README.md`

## Dependencies

- [`jido_action`](https://github.com/agentjido/jido_action)
- [`jido_ai`](https://github.com/agentjido/jido_ai)
- [`jido_signal`](https://github.com/agentjido/jido_signal)
- [`jido_workspace`](https://github.com/agentjido/jido_workspace)
- [`jido_conversation`](https://github.com/pcharbon70/jido_conversation)
- [`jido_workflow`](https://github.com/pcharbon70/jido_workflow)
- [`jido_command`](https://github.com/pcharbon70/jido_command)
- [`jido_skill`](https://github.com/pcharbon70/jido_skill)

## Getting Started

1. Install Homebrew and `asdf`.
2. Install ASDF plugins:
   - `asdf plugin add erlang`
   - `asdf plugin add elixir`
3. Install toolchain from `.tool-versions`:
   - `asdf install`
4. Fetch dependencies:
   - `mix deps.get`
5. Run tests:
   - `mix test`

## Quality Commands

- `mix ci` - format check, compile warnings-as-errors, credo, tests
- `mix quality` - `mix ci` plus dialyzer
- `mix q` - shorthand for `mix quality`
- `mix phase9.bench` - synthetic multi-project load/soak benchmark harness

## Alert Routing

Configure escalation alert dispatch for security and timeout signals:

- `:alert_signal_events` (default includes `security.sandbox_violation`)
- `:alert_router` (callback tuple `{module, function}` or `{module, function, extra_args}`)
