Below is a multi‑phase plan for a **hybrid Credo + LLM** workflow where:

* **Credo is the source of truth** (detects issues, with your real `.credo.exs` config)
* The **LLM is a deterministic fixer** (one check at a time, using your per‑check fix prompts)
* You have **evals** that continuously verify the LLM’s behavior for the 67 checks before you trust it on real code
* After any “LLM coding task” finishes, you run an automated **Credo fix pass** over the modified files.

I’ll assume you want “minimal diffs” and “no behavior changes” by default.

---

## Phase 0 — Define scope, safety rails, and what “done” means

**Goal:** Make the system predictable and safe before you automate edits.

**Decisions to lock in**

1. **Authority:** Credo output is authoritative; LLM never “decides” a violation exists.
2. **Edit policy:**

   * Default: “style-only, no behavior change.”
   * Allowed: whitespace/formatting, alias order, parentheses, boolean readability, simple refactors that preserve semantics.
   * Disallowed without escalation: renaming public APIs, changing function signatures, logic changes.
3. **Scope of review after a coding task:**

   * Start with **changed files only** (fast, low risk), then optionally allow “full project” on demand.
4. **Fix modes per check:** classify each of the 67 checks into:

   * `:autofix` (safe + mechanical)
   * `:suggest` (LLM produces explanation + options, but you don’t auto-apply)
   * `:skip` (requires project-specific judgment / too risky)

**Deliverables**

* A config file like `priv/credo_llm_policy.json` mapping check → mode + any constraints.
* A standard acceptance rule:
  “After post-fix: Credo is clean (in chosen scope) and tests still pass.”

---

## Phase 1 — Build the Credo “detector” interface (machine-readable findings)

**Goal:** Run Credo after a coding task and get a stable `Finding` structure you can route into fixers.

**Key work**

1. Add a runner module that executes Credo in a **machine-readable format** (prefer JSON formatter if available in your setup).
2. Parse results into a canonical struct, e.g.:

```elixir
defmodule MyAssistant.CredoFinding do
  defstruct [
    :check,       # "Credo.Check.Readability.AliasOrder"
    :filename,    # "lib/foo.ex"
    :line, :column,
    :message,
    :trigger,     # the code snippet Credo flags (if provided)
    :severity     # warning/readability/refactor/etc if available
  ]
end
```

3. Collect **file content** and (optionally) an AST or formatted version for better fix context.
4. Implement `scope` helpers:

   * `changed_files_only(diff)` (default)
   * `full_project()` (optional)

**Deliverables**

* `MyAssistant.Credo.run(scope) :: [CredoFinding]`
* Deterministic sorting of findings (stable output makes debugging far easier)

**Acceptance**

* Running Credo on a known broken file yields the expected check names + locations.

---

## Phase 2 — Standardize the LLM “fix contract” (one finding or one check at a time)

**Goal:** Make LLM responses easy to validate + apply, and prevent “creative refactors.”

**Design the response schema (strict JSON)**
At minimum:

```json
{
  "check": "Credo.Check.Readability.AliasOrder",
  "verdict": "pass|fail",
  "violations": [
    {"line": 12, "column": 1, "message": "...", "evidence": "..."}
  ],
  "edits": [
    {"file": "lib/foo.ex", "range": {"start": 120, "end": 168}, "replacement": "..." }
  ]
}
```

**Why “edits” not “diff”?**

* `edits` are easier to validate and apply safely.
* You can also support `unified_diff` later, but edits are more robust for v1.

**Prompting rules**

* One call fixes **one check** (or one finding) at a time.
* Include:

  * check name
  * short rule text
  * params from `.credo.exs`
  * filename
  * **target snippet** (lines around the finding)
  * optionally the whole file if necessary (escalation path)

**Deliverables**

* A `PromptRenderer` that takes `{finding, file_content, params}` → prompt string
* A `ResponseValidator` that rejects non-JSON or schema violations
* A `Mode` that sets temperature to 0 and forces JSON output (where your LLM provider supports it)

**Acceptance**

* The LLM output is always parseable JSON and always includes `edits` only in the targeted file.

---

## Phase 3 — Implement per-check fix prompts and unit evals (your “67 checks suite”)

**Goal:** Make each check-specific fixer predictable and regression-tested.

**Key work**

1. Store prompt specs per check (like your generated list), including:

   * rule description
   * common pitfalls
   * examples
   * parameters
2. For each check, include **eval fixtures**:

   * at least 1 valid + 1 invalid
   * for fix prompts: expected that applying the edit makes the snippet “valid”
3. Write two layers of eval:

### A) Prompt-behavior eval (fast)

* Feed snippet to the prompt and verify schema + verdict correctness.

### B) “Apply-edit then re-run Credo” eval (gold standard)

* Apply the returned edits to a temp file
* Run Credo on that file
* Assert the specific finding is gone

This second layer is what makes the system truly credible.

**Deliverables**

* `test/my_assistant/credo_llm_prompts_test.exs` that:

  * iterates all 67 checks
  * runs unit fixtures
  * for fixable checks, applies edits and runs Credo again

**Acceptance**

* CI can run the full eval suite and give you a clear “which check regressed” signal.

---

## Phase 4 — Build the patch application engine (safe edits + rollback)

**Goal:** Apply LLM edits without corrupting files, and guarantee you can recover if something goes wrong.

**Key work**

1. Apply edits in a **temporary working directory** or git worktree
2. Validate edits before applying:

   * file path matches expected
   * range bounds are valid
   * replacement is not empty when it shouldn’t be
3. Apply edits with strict ordering:

   * apply from bottom-to-top by offset to avoid shifting ranges
4. After applying:

   * run `mix format` on changed files (or at least the touched file)
   * compile check (optional but recommended)
5. If anything fails (format/compile), rollback the file to previous content.

**Deliverables**

* `MyAssistant.Patch.apply_edits!(repo_state, edits) -> {:ok, new_state} | {:error, reason}`
* A “rollback” mechanism (git checkout, temp copy restore, or state snapshot)

**Acceptance**

* Invalid edit ranges never corrupt code; failures are contained and recoverable.

---

## Phase 5 — The post-task “Credo Fix Loop” orchestrator (hybrid workflow)

**Goal:** After an LLM coding task produces code changes, automatically reduce Credo issues using per-check fixers, verifying against Credo after each step.

### Post-task pipeline (high level)

When the coding task finishes:

1. **Collect scope**

   * determine changed files from diff (preferred)
2. **Format first**

   * run formatter once (reduces noise)
3. **Detect**

   * run Credo on scope → findings
4. **Fix loop**

   * for each finding (ordered), run per-check fixer → edits
   * apply edits, reformat file, rerun Credo on that file
5. **Stop conditions**

   * no findings left in scope
   * or max passes reached
   * or repeated failure for same finding (escalate to suggest-only)
6. **Final verification**

   * run Credo on scope again
   * run tests (or at least compilation)

### Recommended ordering (reduces churn)

Fix checks that reduce downstream noise first:

1. Formatting/whitespace-related checks
2. Alias/import ordering
3. Readability naming / predicate naming
4. Refactor checks (nesting, complexity) – often suggest-only initially
5. Warning checks (TODO, debug) – depends on policy

### Orchestrator pseudocode

```elixir
def run_post_task_credo_fix(changed_files, config) do
  format(changed_files)

  findings = credo(changed_files)

  for pass <- 1..config.max_passes do
    findings = credo(changed_files)
    if findings == [], do: break

    findings
    |> order_findings()
    |> Enum.reduce(:ok, fn finding, _acc ->
      mode = policy_mode(finding.check)

      case mode do
        :skip -> :ok
        :suggest -> record_suggestion(finding)
        :autofix ->
          attempt_fix_finding(finding)
      end
    end)
  end

  format(changed_files)
  final_findings = credo(changed_files)
  %{final_findings: final_findings, suggestions: suggestions()}
end
```

**Acceptance**

* On a repo with known Credo issues, the loop reduces findings monotonically and never “thrashes” (reintroducing the same issue repeatedly).

---

## Phase 6 — Review UX: make changes auditable, not magical

**Goal:** Ensure developers can trust and review what happened.

**Key work**

1. Produce a post-run report:

   * how many findings fixed per check
   * remaining findings + why they weren’t auto-fixed
   * links to file/line
2. For each applied fix, include:

   * the Credo message
   * before/after snippet
   * minimal justification (one sentence)
3. Output format options:

   * markdown summary for PR description
   * JSON report for tool integration

**Acceptance**

* A developer can skim the report and quickly approve the changes.

---

## Phase 7 — Maintenance: stay aligned with Credo and models over time

**Goal:** Prevent silent drift.

**Key work**

1. Tie prompts to the **actual enabled checks and parameters** in `.credo.exs`

   * If a check is disabled, don’t run its prompt/evals in your pipeline
2. Make evals mandatory in CI for:

   * prompt changes
   * model changes
   * parameter changes
3. Track metrics:

   * fix success rate per check
   * average number of passes
   * most common failure reasons
4. Add a “shadow mode”:

   * run fixers and produce diffs, but don’t apply
   * use this during rollout

**Acceptance**

* You can upgrade Credo or swap models and immediately see what broke (per-check).

---

## Practical recommendation: how to roll this out without boiling the ocean

Even though you *can* stand up all 67 checks, roll out in layers:

1. Start with the “safe mechanical” subset as `:autofix` (whitespace, alias order, simple readability).
2. Make the rest `:suggest` (LLM proposes change, human approves).
3. Promote checks to `:autofix` only once:

   * unit evals pass
   * apply-and-rerun-Credo evals pass
   * real-repo shadow mode looks good

This gives you the hybrid system immediately, without risking big semantic refactors.

---

