#!/usr/bin/env bash
# =============================================================================
# check.sh — every static check + standalone regression; MUST pass before a commit.
#
#   1. stylua --check  : formatting of src/ (fails if any file is not formatted)
#   2. selene          : lint of src/ (Roblox std library aware; selene.toml)
#   3. typecheck.sh    : strict Luau type-check via luau-lsp (our `tsc --noEmit`)
#   4. compilecheck.sh : compile every file like Studio does (catches compiler limits such as
#                        "Out of local registers", which break the server bootstrap)
#   5. test-logic.sh   : lune regressions in tests/*.luau (pure logic; Studio tests are separate)
#
# Tool binaries come from scripts/lib/tools.sh (the exact versions aftman.toml pins).
#
# Usage:  ./scripts/check.sh        (run from anywhere)
#         ./scripts/check.sh --fix  (auto-format src/ with stylua first — LEAD ONLY: workers format
#                                    only their own files, never the shared tree)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/tools.sh

STYLUA="$(resolve_tool stylua)"
SELENE="$(resolve_tool selene)"

if [[ "${1:-}" == "--fix" ]]; then
	"$STYLUA" src
fi

echo "[check] stylua"
"$STYLUA" --check src
echo "[check] selene"
"$SELENE" src
echo "[check] typecheck"
./scripts/typecheck.sh
echo "[check] compile"
./scripts/compilecheck.sh
echo "[check] standalone logic"
./scripts/test-logic.sh
echo "[check] ALL PASSED"
