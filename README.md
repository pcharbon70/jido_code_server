# Jido Code Server

Elixir runtime scaffold for the Jido code server project.

## Dependencies

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
