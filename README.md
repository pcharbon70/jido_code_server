# Jido Code Server

Elixir runtime scaffold for the Jido.Code.Server project.

## Status

Implemented phases:

- OTP application entrypoint and top-level engine supervisor scaffold
- Engine-level multi-project lifecycle (`start_project`, `stop_project`, `whereis_project`, `list_projects`)
- Project-level runtime container and conversation lifecycle shell (`Project.Supervisor`, `Project.Server`, `Project.Layout`)
- Runtime namespace skeleton (`Engine`, `Project`, `Conversation`, `Protocol`, `Telemetry`, `Types`)
- Core dependency wiring for Jido ecosystem libraries
- Baseline test fixtures and fake adapters for upcoming phase work

Roadmap source:

- `notes/planning/runtime_implementation_plan.md`

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
