# Security Model

This guide summarizes built-in runtime security controls and safe configuration practices.

## Security Goals

- Keep tool execution inside a project-scoped trust boundary.
- Enforce deny-by-default behavior for high-risk capabilities.
- Preserve auditability and incident reconstruction metadata.

## Control Matrix

| Threat Area | Primary Controls | Main Modules |
| --- | --- | --- |
| Sandbox escape | Realpath normalization, outside-root deny by default, reason-coded exceptions | `Project.Policy` |
| Sensitive file access | Denylist + allowlist checks, telemetry on denial | `Project.Policy`, `Config` |
| Network egress abuse | `network_egress_policy`, allowlist, scheme restrictions, nested payload extraction | `Project.Policy` |
| Invalid/malicious tool args | Schema validation, required/additional/type checks | `Project.ToolRunner` |
| Resource exhaustion | Timeout limits, output/artifact caps, concurrency caps | `Project.ToolRunner`, `Config` |
| Stuck external processes | Child PID tracking and termination on cancel/timeout | `Project.ToolRunner`, `WorkspaceShell` |
| Env secret leakage | `env` deny-by-default with explicit allowlist | `Project.ToolRunner` |
| Protocol surface expansion | Project `protocol_allowlist` checks and denied telemetry | `Project.Server`, protocol gateways |
| Sub-agent privilege escalation | Template-gated spawn tools, template allowlist policy, per-conversation quotas/TTL | `ToolCatalog`, `Policy`, `SubAgentManager` |
| Secret leakage in telemetry | Key and pattern-based redaction before persistence/emission | `Telemetry` |
| Poor incident traceability | Correlation IDs and policy/tool decision telemetry | `Correlation`, `Policy`, `Telemetry` |

## Secure Defaults

Defaults in `Config` intentionally bias to safety:

- `network_egress_policy: :deny`
- sensitive path denylist includes `.env`, key files, SSH private keys
- protocol allowlist limited to `mcp` and `a2a`
- bounded telemetry buffers for recent events/errors

## High-Impact Runtime Options

When starting a project, review these options carefully:

- `allow_tools`, `deny_tools`
- `network_egress_policy`, `network_allowlist`, `network_allowed_schemes`
- `outside_root_allowlist` (must include `reason_code`)
- `sensitive_path_denylist`, `sensitive_path_allowlist`
- `tool_env_allowlist`
- `tool_timeout_ms`, `tool_max_output_bytes`, `tool_max_artifact_bytes`, concurrency knobs
- `command_executor` (for workspace-shell isolation mode)

## Policy Decision Audit Trail

Each authorization decision records:

- `project_id`
- `conversation_id`
- `correlation_id`
- `tool_name`
- decision reason and timestamp

Security-relevant denials emit telemetry events such as:

- `security.sandbox_violation`
- `security.sandbox_exception_used`
- `security.network_denied`
- `security.sensitive_path_denied`
- `security.env_denied`
- `security.protocol_denied`
- `security.subagent.spawn_denied`
- `security.subagent.quota_denied`
- `security.subagent.policy_violation`

## Validation Strategy

Security controls are exercised in:

- `test/jido_code_server/runtime_hardening_test.exs`
- `test/jido_code_server/tool_runtime_policy_test.exs`
- `test/jido_code_server/protocol_gateway_test.exs`
- `test/jido_code_server/alert_router_test.exs`

For operational expectations, see:

- `notes/planning/phase9_hardening_report.md`
- `notes/planning/phase9_release_checklist.md`
- `notes/planning/phase9_operations_runbook.md`
