#!/usr/bin/env bash
# =============================================================================
# compilecheck.sh — compile every Luau source with the Luau bytecode compiler.
#
# Why: luau-lsp (types) and selene (lint) do not run the COMPILER, so compiler limits slip
# through — e.g. "Out of local registers ... exceeded limit 200" (more than 200 locals live in
# one function; a module's top-level chunk counts as one function). Roblox Studio compiles
# scripts without optimisation and with full debug info, which keeps every local in a register,
# so we compile the same way (-O0 -g2): a file that passes here loads in Studio. A module that
# fails to compile breaks the whole server bootstrap (every playtest hangs), so this is a gate.
#
# Requires `luau-compile` (Homebrew: `brew install luau`). Missing tools fail verification.
# Usage: ./scripts/compilecheck.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v luau-compile >/dev/null 2>&1; then
	echo "[compilecheck] luau-compile is required (brew install luau); compile check cannot run" >&2
	exit 1
fi

# Preserve process status as well as diagnostics: a crashed/unavailable compiler may never
# print CompileError/SyntaxError. pipefail also makes a failed source discovery fail the gate.
if ! output="$(find src -name '*.luau' -print0 | xargs -0 -n 40 luau-compile --null -O0 -g2 2>&1)"; then
	printf '%s\n' "$output"
	echo "[compilecheck] FAILED: compiler or source discovery exited unsuccessfully"
	exit 1
fi
errors="$(printf '%s\n' "$output" | grep -E 'CompileError|SyntaxError' || true)"
if [[ -n "$errors" ]]; then
	printf '%s\n' "$errors"
	echo "[compilecheck] FAILED"
	exit 1
fi
echo "[compilecheck] OK"
