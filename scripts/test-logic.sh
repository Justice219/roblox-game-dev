#!/usr/bin/env bash
# =============================================================================
# test-logic.sh — run the standalone lune regressions (tests/*.luau) in a stable order.
#
# These load the REAL production modules from src/ (tests/fixtures/RobloxLoader.luau supplies
# Roblox globals and service stubs where a module needs them) and test pure logic: number
# formatting, profile schema / receipts, delta sync, validators, change notes, the economy
# pacing simulator. They supplement, never replace, Studio play-mode checks.
#
# Only top-level tests/*.luau files are suites; tests/fixtures/ holds shared helpers.
# Usage: ./scripts/test-logic.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/tools.sh

LUNE="$(resolve_tool lune)"

# A missing test directory must fail rather than report a misleading empty green suite.
shopt -s nullglob
tests=(tests/*.luau)
if (( ${#tests[@]} == 0 )); then
	echo "[logic] No standalone Luau regression files found." >&2
	exit 1
fi
for test_file in "${tests[@]}"; do
	echo "[logic] ${test_file}"
	"$LUNE" run "${test_file}"
done
echo "[logic] All ${#tests[@]} standalone suites passed; Studio checks are separate."
