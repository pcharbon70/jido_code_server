# 12. Mode and Strategy Extension Model

Prev: [11. Testing and Quality](./11-testing-and-quality.md)  
Next: `None`

## Purpose

This guide defines how to add new conversation modes and strategy adapters
without breaking determinism, policy enforcement, or cross-repo contracts.

## Mode Template Contract

Mode behavior is composed from:

- `Conversation.ModeRegistry` for capabilities and execution-kind policy
- `Conversation.Domain.ModePipeline` for template metadata and step chain
- reducer intent planning (`Conversation.Domain.Reducer`)

Each mode spec must define:

- `mode`, `title`, `description`
- `defaults` (must include `"strategy"` and bounded turn controls)
- `capabilities.strategy_support`
- `capabilities.tool_policy.allowed_execution_kinds`
- interruption semantics (`supports_cancel`, `supports_resume`)

Each pipeline template must define:

- `template_id`, `template_version`
- `step_chain`
- `continue_on`
- `terminal_signals`
- `extension_points`
- `output_profile`

## Strategy Adapter Contract

Strategy adapters implement `Project.StrategyRunner` callbacks:

- `start/3` (required)
- `capabilities/0` (required)
- `stream/3` (optional)
- `cancel/3` (optional)

Capabilities must accurately declare:

- `supported_strategies`
- `tool_calling?`
- `streaming?`
- `cancellable?`

`ExecutionRunner` delegates only after `StrategyRunner.prepare/2` validates:

- mode-strategy compatibility
- runner validity
- runner capability compatibility

## ExecutionRunner Delegation Rules

All execution kinds are gated by mode policy before dispatch:

- `:strategy_run` -> `StrategyRunner`
- `:tool_run` -> `ToolRunner`
- `:command_run` -> `CommandRunner`
- `:workflow_run` -> `WorkflowRunner`
- `:subagent_spawn` -> `ToolRunner` spawn path

Rules:

1. Never execute directly from reducer or instruction modules.
2. Always pass through `ExecutionRunner` policy and limit checks.
3. Ensure tool exposure (`ToolCatalog.llm_tools/2`) and runtime execution
   (`ToolCatalog.llm_tool_allowed?/3` + `ExecutionRunner`) stay aligned.

## Required Test Coverage for New Mode/Strategy Work

Minimum test updates per feature:

1. Mode registry/pipeline tests:
   - mode normalization and defaulting
   - allowed execution kinds
   - pipeline continuation and terminal behavior
2. Reducer tests:
   - run open/close lifecycle with new mode
   - interruption and resume semantics
3. Strategy runner tests:
   - `prepare/2` support validation
   - success/error normalization
4. Execution gateway tests:
   - policy denial behavior
   - execution-kind enforcement by mode
5. Cross-repo contract gates:
   - canonical `conversation.*` -> `conv.*` parity
   - replay/timeline parity and determinism checks

## Execution-Kind Contract Governance

Changes to execution kinds are contract changes and require explicit review.

Review checklist:

1. Does `ModeRegistry.allowed_execution_kinds/2` still represent a safe default?
2. Are `ExecutionEnvelope` mappings and normalization updated?
3. Does `ExecutionRunner` enforce and emit telemetry for the new kind?
4. Are tool/strategy exposure paths and policy checks still consistent?
5. Were cross-repo fixture and contract tests updated with migration notes?

Approval criteria:

- no bypass around `ExecutionRunner`
- deterministic replay remains stable
- policy denial and limit failures are observable and test-covered
- documentation updates in both `jido_code_server` and `jido_conversation`
