#!/usr/bin/env bash
# =============================================================================
# typecheck.sh — strict Luau type-check for SellNukes (our equivalent of `tsc --noEmit`)
#
# What it does:
#   1. Downloads Roblox global type definitions matching the luau-lsp version pinned in
#      aftman.toml into .luau-defs/ the first time, or when REFRESH_DEFS=1.
#   2. Regenerates sourcemap.json from default.project.json so luau-lsp can resolve
#      `ReplicatedStorage.Shared...` / `script.Parent...` requires.
#   3. Runs `luau-lsp analyze` over src/ with strict DataModel types (.luaurc: strict).
#
# Usage:
#   ./scripts/typecheck.sh                  # normal run
#   REFRESH_DEFS=1 ./scripts/typecheck.sh   # re-download the type definitions
#
# Exit code is non-zero if any type error is found, so it is CI-safe.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/tools.sh

ROJO="$(resolve_tool rojo)"
LUAU_LSP="$(resolve_tool luau-lsp)"

# Keep the definitions in lock-step with the luau-lsp binary pinned in aftman.toml.
LSP_VERSION="$(pinned_version luau-lsp)"
if [[ -z "$LSP_VERSION" ]]; then
	LSP_VERSION="$("$LUAU_LSP" --version | tr -d '[:space:]')"
fi
DEFS_DIR=".luau-defs"
DEFS_FILE="$DEFS_DIR/globalTypes.None.d.luau"
DOCS_FILE="$DEFS_DIR/en-us.json"
BASE_URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LSP_VERSION}/scripts"

if [[ ! -f "$DEFS_FILE" || "${REFRESH_DEFS:-0}" == "1" ]]; then
	mkdir -p "$DEFS_DIR"
	echo "[typecheck] Downloading Roblox type definitions for luau-lsp ${LSP_VERSION}..."
	# "None" security level = what normal game Scripts/LocalScripts may call, so accidental use
	# of plugin-only / CoreScript APIs is a type error.
	curl --fail --silent --show-error --location --max-time 60 \
		"${BASE_URL}/globalTypes.None.d.luau" -o "$DEFS_FILE"
	curl --fail --silent --show-error --location --max-time 60 \
		"${BASE_URL}/api-docs/en-us.json" -o "$DOCS_FILE"
fi

"$ROJO" sourcemap default.project.json --output sourcemap.json

# LuauSolverV2 = the new Luau type solver (the one Roblox Studio is rolling out). The legacy
# solver wrongly widens string-literal unions on local assignment ("a" | "b" -> string); the new
# solver handles them and still catches real bugs (same setting as RoBeasts).
"$LUAU_LSP" analyze \
	--flag:LuauSolverV2=true \
	--platform=roblox \
	--sourcemap=sourcemap.json \
	--definitions=@roblox="$DEFS_FILE" \
	--base-luaurc=.luaurc \
	src
echo "[typecheck] OK"
