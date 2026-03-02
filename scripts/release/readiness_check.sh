#!/usr/bin/env bash
set -euo pipefail

echo "[release-readiness] validating governance docs"
required_docs=(
  "docs/developer/13-release-governance-and-readiness.md"
)

for file in "${required_docs[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[release-readiness] missing required document: $file" >&2
    exit 1
  fi
done

echo "[release-readiness] running cross-repo contract and orchestration suites"
mix test \
  test/jido_code_server/phase8_contract_gates_test.exs \
  test/jido_code_server/conversation_orchestration_test.exs \
  test/jido_code_server/conversation_mode_registry_config_test.exs

echo "[release-readiness] running execution/cancellation suites"
mix test \
  test/jido_code_server/conversation_run_execution_instruction_test.exs \
  test/jido_code_server/conversation_cancel_active_strategy_instruction_test.exs

echo "[release-readiness] passed"
