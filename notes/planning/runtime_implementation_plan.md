# Jido.Code.Server Runtime Implementation Plan (Phased)

## 1. Inputs and Alignment

This plan is derived from:

- `notes/research/architecture.md`
- `notes/research/module_specs.md`

It preserves the core architectural constraints from those documents:

1. `Project` is the isolation and policy boundary (supervision, assets, sandbox, tool execution).
2. `Conversation` is a `JidoConversation` runtime instance (event ingestion + projections).
3. Protocols and UIs are adapters only (no alternate runtime state machines).
4. All tool execution flows through one project-scoped pathway (`Policy` -> `ToolRunner`).
5. Conversation state is event-driven and treated as the source of truth.

## 2. Current Baseline

Current repository state appears documentation-only (no runtime code scaffold yet).  
This plan therefore includes both:

- platform bootstrap work (application skeleton and module scaffolding), and
- staged implementation of the runtime modules defined in `module_specs.md`.

## 3. Delivery Strategy

Implementation should proceed as a sequence of vertical slices with strict phase gates:

- Every phase delivers executable code, tests, and an API/contract checkpoint.
- No phase may introduce a second execution path for tools.
- Protocol adapters are added only after core engine/project/conversation correctness is stable.
- Optional modules (`Watcher`, protocol servers) are deferred until core behavior is validated.

Suggested cadence: 9 phases across ~10-12 weeks for one engineer, or ~6-8 weeks for a small team.

## 4. Phase Plan

## Phase 0 - Program Setup and Bootstrap

### Objectives

- Create a runnable OTP application baseline.
- Establish coding, testing, and observability conventions before module implementation.

### Modules/Areas

- `Jido.Code.Server.Application` (initial scaffold)
- Build/test/tooling configuration
- Core dependency setup (`JidoConversation`, `JidoAction`, `JidoAi`, `JidoSignal`, optional protocol deps)

### Work Packages

1. Initialize project/application scaffold and dependency graph.
2. Define common compile/runtime config for:
   - project ID generation
   - default data directory (`.jido`)
   - timeout defaults
3. Create base namespaces and empty module stubs for all planned modules.
4. Establish test support:
   - fixture project roots
   - helper for temporary sandboxes
   - fake action + fake LLM adapters
5. Add CI baseline (format, lint, test).

### Deliverables

- Compiling OTP app with placeholder modules.
- Passing baseline CI.
- `README` section documenting runtime architecture and phase boundaries.

### Exit Criteria

- Application boots with no warnings/errors.
- CI passes on clean checkout.
- Required dependencies are pinned and loaded.

---

## Phase 1 - Engine Core and Public Facade

### Objectives

- Deliver multi-project lifecycle management and stable facade API.

### Modules

- `Jido.Code.Server`
- `Jido.Code.Server.Engine`
- `Jido.Code.Server.Engine.Supervisor`
- `Jido.Code.Server.Engine.ProjectRegistry`
- `Jido.Code.Server.Engine.ProtocolSupervisor` (stub only)

### Work Packages

1. Implement top-level supervision tree:
   - project registry
   - dynamic project supervisor
   - optional protocol supervisor stub
2. Implement engine API:
   - `start_project/2`, `stop_project/1`, `whereis_project/1`, `list_projects/0`
3. Implement facade API delegating to engine.
4. Define and document `project_id` semantics (UUID/ULID).
5. Add robust error contracts for not-found, duplicate start, and startup failures.

### Deliverables

- Working project lifecycle entrypoints from `Jido.Code.Server`.
- Registry-backed project lookup/listing.
- Unit/integration tests for project lifecycle behavior.

### Exit Criteria

- Can start and stop multiple project instances in parallel.
- `list_projects/0` reflects real process lifecycle.
- No global atom naming required for project processes.

---

## Phase 2 - Project Container, Layout, and Conversation Lifecycle Shell

### Objectives

- Implement project supervision boundary and filesystem layout management.
- Wire conversation supervisor/registry lifecycle (conversation internals still stubbed).

### Modules

- `Jido.Code.Server.Project.Supervisor`
- `Jido.Code.Server.Project.Server`
- `Jido.Code.Server.Project.Layout`
- `Jido.Code.Server.Project.ConversationRegistry`
- `Jido.Code.Server.Project.ConversationSupervisor`

### Work Packages

1. Build per-project supervisor child specs and `via` naming.
2. Implement `Project.Layout.paths/2` + `ensure_layout!/2`.
3. On project startup:
   - canonicalize and validate `root_path`
   - ensure `.jido/{skills,commands,workflows,skill_graph,state}` exists
4. Implement project control plane (`Project.Server`) with:
   - conversation start/stop routing
   - event forwarding shell
   - projection request routing shell
5. Add initial signals for `project.started` and `project.stopped`.

### Deliverables

- Project process tree boots with required children.
- Filesystem layout is created/validated deterministically.
- Conversation supervisor can create and stop placeholder conversation workers.

### Exit Criteria

- Starting a project with invalid/outside path fails cleanly.
- Project startup is idempotent for existing `.jido` layout.
- Conversation processes are isolated per project instance.

---

## Phase 3 - Shared Asset System (Loaders + ETS Store + Reload)

### Objectives

- Implement shared, project-local asset loading and query APIs.
- Ensure conversations consume assets read-only from `AssetStore`.

### Modules

- `Jido.Code.Server.Project.AssetStore`
- `Jido.Code.Server.Project.Loaders.Skill`
- `Jido.Code.Server.Project.Loaders.Command`
- `Jido.Code.Server.Project.Loaders.Workflow`
- `Jido.Code.Server.Project.Loaders.SkillGraph`
- `Jido.Code.Server.Project.Server` (`reload_assets` and list/query integration)

### Work Packages

1. Implement ETS-backed store with typed key scheme:
   - `{:skill, name}`
   - `{:command, name}`
   - `{:workflow, name}`
   - `{:skill_graph, :snapshot}`
2. Implement loader contracts and error aggregation:
   - parse failures do not crash project unless configured strict
3. Integrate asset load on project boot and reload on demand.
4. Version loaded snapshots (`versions` map) for diagnostics and cache invalidation.
5. Add list/get/search APIs used by conversations and adapters.
6. Emit `project.assets_loaded` and `project.assets_reloaded`.

### Deliverables

- Asset ingestion from `.jido` directories into ETS.
- Runtime APIs for asset access by type.
- Reload path with deterministic version bumping.

### Exit Criteria

- Asset data is shared across conversations without duplication.
- Reload updates store atomically (no mixed partial snapshots).
- Loader errors are visible in diagnostics/tests.

---

## Phase 4 - Policy, Tool Catalog, and Unified Tool Runner

### Objectives

- Enforce project sandbox policy.
- Deliver single execution pathway for all tool calls.

### Modules

- `Jido.Code.Server.Project.Policy`
- `Jido.Code.Server.Project.ToolCatalog`
- `Jido.Code.Server.Project.ToolRunner`
- `Jido.Code.Server.Project.TaskSupervisor`

### Work Packages

1. Implement path normalization and traversal prevention:
   - `realpath` canonicalization
   - symlink escape checks
   - deny outside `root_path` by default
2. Implement tool authorization and project-level allow/deny policy.
3. Implement tool catalog composition:
   - built-in `JidoAction` tools
   - assets-backed tools (commands/workflows/graph queries)
   - optional custom tools extension point
4. Implement `ToolRunner` with:
   - policy check preflight
   - task-supervisor execution with timeouts/concurrency limits
   - normalized success/error payload schema
5. Ensure `Project.Server.list_tools/0` returns policy-filtered inventory.
6. Emit `tool.started`, `tool.completed`, `tool.failed`.

### Deliverables

- Production-ready sandbox enforcement.
- Structured tool invocation and result pipeline.
- Reliable task cancellation/timeout behavior.

### Exit Criteria

- All tool requests pass through `Policy` then `ToolRunner`.
- Escaping sandbox paths is rejected in tests.
- Timeouts and cancellation produce deterministic error payloads.

---

## Phase 5 - Conversation Runtime Core (`JidoConversation` Wrapper)

### Objectives

- Implement conversation process as a thin runtime wrapper with projections.
- Keep orchestration logic outside process plumbing and aligned with event model.

### Modules

- `Jido.Code.Server.Conversation.Server`
- `Jido.Code.Server.Conversation.Loop`
- `Jido.Code.Server.Types.Event`
- `Jido.Code.Server.Types.ToolCall`
- `Jido.Code.Server.Types.ToolSpec`
- `Jido.Code.Server.Project.Server` (full event/projection integration)

### Work Packages

1. Implement `Conversation.Server` state:
   - `project_id`
   - `conversation_id`
   - `JidoConversation.t`
   - subscriber set
   - optional projection cache
2. Implement inbound event ingest flow (`cast {:event, event}`).
3. Implement projection query API (`call {:get_projection, key}`).
4. Implement subscriber API and outbound notifications.
5. Implement `Conversation.Loop.after_ingest/2` decision contract.
6. Ensure project routes:
   - `send_event` -> conversation ingest
   - `get_projection` -> conversation projection read

### Deliverables

- Deterministic event ingestion and projection retrieval.
- Conversation-level publish/subscribe notifications.
- Clean separation between process wrapper and decision logic.

### Exit Criteria

- Given the same event sequence, projections are deterministic.
- Conversation process remains thin (no direct protocol/tool policy logic).
- Lifecycle APIs support start/stop/restart without project disruption.

---

## Phase 6 - LLM and Tool-Orchestration Loop

### Objectives

- Connect LLM completion flow and tool requests to conversation events.
- Preserve event spine: `user.message` -> ingest -> (LLM/tool events) -> ingest.

### Modules

- `Jido.Code.Server.Conversation.LLM`
- `Jido.Code.Server.Conversation.ToolBridge`
- `Jido.Code.Server.Conversation.Loop` (full orchestration behavior)
- `Jido.Code.Server.Project.ToolRunner` (runtime integration)

### Work Packages

1. Implement LLM adapter around `JidoAi`:
   - build prompt from `:llm_context` projection
   - attach policy-filtered tool specs
   - stream delta events back into conversation
2. Convert LLM tool-call intents into `tool.requested` events.
3. Implement `ToolBridge` to execute requests through project `ToolRunner`.
4. Feed `tool.completed`/`tool.failed` back into conversation ingest loop.
5. Add cancellation semantics (`conversation.cancel` -> LLM cancel + task cancel).

### Deliverables

- End-to-end conversational loop with tool use.
- Streaming and tool execution reflected in event timeline.

### Exit Criteria

- Tool calls initiated by LLM never bypass project policy.
- Failed tools are represented as events and recoverable by loop logic.
- Conversation can continue after tool failures when policy/logic allows.

---

## Phase 7 - Telemetry, Diagnostics, and Asset Hot Reload

### Objectives

- Add operational visibility and optional file watcher-driven reload.

### Modules

- `Jido.Code.Server.Telemetry`
- `Jido.Code.Server.Project.Watcher` (optional, now implemented)
- Additional diagnostics endpoints in `Project.Server`/`Conversation.Server`

### Work Packages

1. Centralize signal emission helper and payload schema conventions.
2. Emit all recommended events:
   - project lifecycle
   - assets loaded/reloaded
   - conversation ingest
   - LLM lifecycle
   - tool lifecycle
3. Implement optional `.jido/*` watcher with debounced reload.
4. Add diagnostics surfaces:
   - project health snapshot
   - conversation status snapshot
   - recent error counters

### Deliverables

- Consistent telemetry stream for UIs/protocols/monitoring.
- Automatic asset refresh path (if enabled).
- Operator-friendly diagnostics.

### Exit Criteria

- Signals include stable correlation fields (`project_id`, `conversation_id`, `request_id` where relevant).
- Watcher reload path is debounced and race-safe.
- Diagnostics allow triage without attaching a debugger.

---

## Phase 8 - Protocol Adapters (MCP and A2A)

### Objectives

- Expose runtime capabilities through adapter layers without introducing state duplication.

### Modules

- `Jido.Code.Server.Protocol.MCP.Gateway`
- `Jido.Code.Server.Protocol.MCP.ProjectServer` (optional)
- `Jido.Code.Server.Protocol.A2A.Gateway`
- `Jido.Code.Server.Engine.ProtocolSupervisor` (activate with real children)

### Work Packages

1. Implement MCP tool list and tool call mapping:
   - `tools/list` -> project tool inventory
   - `tools/call` -> project `ToolRunner`
2. Add optional MCP chat/event mapping into conversation events.
3. Implement A2A task/message mapping:
   - `task.create` -> start conversation + `user.message`
   - `message.send` -> `user.message`
   - `task.cancel` -> cancellation event
4. Implement streaming/progress by subscribing to telemetry/conversation events.
5. Harden auth/config boundaries for multi-project exposure.

### Deliverables

- Working MCP integration for tool discovery/execution.
- Working A2A integration for session/task workflows.
- Protocol lifecycle supervision decoupled from core runtime.

### Exit Criteria

- Protocol adapters remain stateless translators over core APIs.
- Adapter failures do not corrupt project/conversation state.
- Multi-project routing correctness validated in integration tests.

---

## Phase 9 - Hardening, Performance, and Release Readiness

### Objectives

- Validate reliability/security/performance under realistic workload.

### Modules/Areas

- All runtime modules
- Benchmarks, fault-injection tests, security review artifacts

### Work Packages

1. Load and soak testing:
   - many projects, many concurrent conversations
   - tool-heavy workloads and long-running tasks
2. Failure injection:
   - loader parse failures
   - tool crashes/timeouts
   - LLM failures/cancellations
   - watcher storms
3. Security review:
   - sandbox bypass attempts
   - protocol boundary review
   - secrets handling
4. Operational readiness:
   - runbooks
   - metrics dashboards
   - on-call alert thresholds

### Deliverables

- Hardening report with measured limits and known constraints.
- Release checklist with sign-off criteria.

### Exit Criteria

- No P0/P1 security or correctness defects open.
- Target concurrency and latency SLOs met.
- Runbooks and diagnostics complete for production rollout.

## 5. Module-to-Phase Mapping

| Module | Phase |
| --- | --- |
| `Jido.Code.Server` | 1 |
| `Jido.Code.Server.Application` | 0 |
| `Jido.Code.Server.Engine.Supervisor` | 1 |
| `Jido.Code.Server.Engine.ProjectRegistry` | 1 |
| `Jido.Code.Server.Engine` | 1 |
| `Jido.Code.Server.Engine.ProtocolSupervisor` | 1 (stub), 8 (active) |
| `Jido.Code.Server.Project.Supervisor` | 2 |
| `Jido.Code.Server.Project.Server` | 2, 3, 5 |
| `Jido.Code.Server.Project.Layout` | 2 |
| `Jido.Code.Server.Project.AssetStore` | 3 |
| `Jido.Code.Server.Project.Loaders.Skill` | 3 |
| `Jido.Code.Server.Project.Loaders.Command` | 3 |
| `Jido.Code.Server.Project.Loaders.Workflow` | 3 |
| `Jido.Code.Server.Project.Loaders.SkillGraph` | 3 |
| `Jido.Code.Server.Project.Policy` | 4 |
| `Jido.Code.Server.Project.ToolCatalog` | 4 |
| `Jido.Code.Server.Project.ToolRunner` | 4, 6 |
| `Jido.Code.Server.Project.Watcher` | 7 |
| `Jido.Code.Server.Project.ConversationRegistry` | 2 |
| `Jido.Code.Server.Project.ConversationSupervisor` | 2 |
| `Jido.Code.Server.Conversation.Server` | 5 |
| `Jido.Code.Server.Conversation.Loop` | 5, 6 |
| `Jido.Code.Server.Conversation.LLM` | 6 |
| `Jido.Code.Server.Conversation.ToolBridge` | 6 |
| `Jido.Code.Server.Protocol.MCP.Gateway` | 8 |
| `Jido.Code.Server.Protocol.MCP.ProjectServer` | 8 |
| `Jido.Code.Server.Protocol.A2A.Gateway` | 8 |
| `Jido.Code.Server.Telemetry` | 7 |
| `Jido.Code.Server.Types.Event` | 5 |
| `Jido.Code.Server.Types.ToolSpec` | 5 |
| `Jido.Code.Server.Types.ToolCall` | 5 |

## 6. Cross-Phase Non-Negotiables

1. **Single tool path:** all tool execution remains `Policy` -> `ToolRunner`.
2. **Adapter purity:** MCP/A2A/UI layers do not own runtime state.
3. **Deterministic conversation model:** behavior is driven by event ingestion/projections.
4. **Project isolation:** each project instance maintains isolated supervision, registries, and policies.
5. **Safe defaults:** deny sandbox escape unless explicitly configured.

## 7. Test Strategy by Maturity Stage

### Unit (Phases 1-6)

- API contract tests for each module.
- Policy/path normalization edge cases.
- Loader parsing and error handling.
- Conversation ingest/projection determinism.

### Integration (Phases 4-8)

- End-to-end event loop with real tool calls.
- Multi-project isolation tests.
- MCP/A2A mapping correctness.

### Non-functional (Phases 7-9)

- Performance and concurrency benchmarks.
- Fault recovery and restart behavior.
- Security hardening scenarios.

## 8. Risks and Mitigations

| Risk | Likely Phase | Mitigation |
| --- | --- | --- |
| Runtime logic leaks into adapters | 6-8 | Enforce adapter-only code review checklist and contract tests. |
| Sandbox bypass via symlink/path edge cases | 4, 9 | Comprehensive canonicalization tests + deny-by-default policy. |
| Asset reload race conditions | 3, 7 | Atomic ETS swap/versioning and debounced watcher behavior. |
| Event schema drift between modules | 5-8 | Central event/type contracts and compile-time checks where possible. |
| Tool execution instability under load | 4, 9 | Task supervisor limits, timeout policy, load tests, and backpressure rules. |

## 9. Concrete Security Controls (Mandatory)

This section defines required controls to implement in addition to the phase plan.

### 9.1 Filesystem Sandboxing Controls

1. All filesystem arguments must be canonicalized using `realpath` before policy checks.
2. Any resolved path outside project `root_path` must be denied by default.
3. Symlink traversal that escapes `root_path` must be blocked.
4. Tool execution working directory must always be the project `root_path`.
5. Any outside-root exception must require explicit project-level allowlisting with reason codes.

### 9.2 Tool and Command Execution Controls

1. Tool invocation must be restricted to policy-filtered tool names from `ToolCatalog`.
2. Every tool call must pass schema validation before execution.
3. Shell command tools must use structured argv execution, not unsanitized string interpolation.
4. Each tool execution must enforce hard timeout, output size caps, and artifact size limits.
5. Process groups started by tools must be terminated on timeout or cancellation.
6. Environment inheritance must be minimal by default and explicitly controlled.

### 9.3 Process Isolation Controls

1. Tool execution must run in isolated worker processes managed by `Project.TaskSupervisor`.
2. Concurrency quotas must exist at project and conversation scope.
3. Long-running tools must be cancellable via conversation and project lifecycle signals.
4. Optional stronger isolation mode (container or sandboxed runner) should be supported behind configuration.

### 9.4 Network Egress Controls

1. Default network policy for tool execution should be deny unless explicitly enabled.
2. If enabled, egress must be constrained by allowlisted domains or endpoints per project.
3. High-risk protocols should be denied by default unless specifically needed.
4. Network-capable tools must be clearly marked in tool metadata for policy filtering and audit.

### 9.5 Secrets and Sensitive Data Controls

1. Secrets must not be embedded in prompts, asset files, or static configs in plaintext.
2. Tool/LLM logs and telemetry must redact known secret patterns before persistence or emission.
3. Sensitive files should be denylisted by policy unless explicitly allowed.
4. Temporary credentials should be short-lived and scoped to the minimum required operation.
5. Tool result payloads should be classified and flagged when they contain potentially sensitive artifacts.

### 9.6 Auditability and Incident Response Controls

1. Every policy decision must produce an auditable record with `project_id`, `conversation_id`, `tool_name`, and decision reason.
2. Security-relevant events (`policy.denied`, sandbox violations, repeated timeout failures) must emit telemetry signals.
3. Correlation IDs must be propagated through event ingest, LLM calls, and tool execution.
4. The runtime must support extracting a bounded incident timeline from conversation events and telemetry.

### 9.7 Security Gates by Phase

| Gate | Phase | Required Evidence |
| --- | --- | --- |
| Sandbox correctness gate | 4 | Unit/property tests proving outside-root and symlink escape denial. |
| Tool execution safety gate | 4, 6 | Tests for timeout kill, schema rejection, and allowed-tool enforcement. |
| Secrets redaction gate | 7 | Telemetry/log tests verifying sensitive-token masking. |
| Adapter boundary gate | 8 | Integration tests proving MCP/A2A cannot bypass `Policy` or `ToolRunner`. |
| Hardening sign-off gate | 9 | Security test report including bypass attempts and residual risk log. |

## 10. Definition of Done (Program-Level)

The runtime is considered complete when all are true:

1. Core APIs from `Jido.Code.Server` are stable and documented.
2. Multi-project and multi-conversation isolation is proven by integration tests.
3. Conversation runtime behavior is event-driven and deterministic.
4. All tool calls are policy-gated and executed via project `ToolRunner`.
5. Asset lifecycle (load, query, reload) is production-safe.
6. Telemetry provides actionable operational visibility.
7. MCP/A2A adapters operate as stateless translators over core APIs.
8. Security/performance hardening gates are passed.
