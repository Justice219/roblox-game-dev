#!/usr/bin/env bash
# =============================================================================
# tools.sh — resolve the aftman-pinned toolchain binaries (sourced by the check scripts).
#
# Why: aftman installs one shim per tool in ~/.aftman/bin that re-execs the pinned binary from
# ~/.aftman/tool-storage/<owner>/<tool>/<version>/<tool>. On this machine (2026-10-30) the shims
# for the large binaries (rojo, luau-lsp) are SIGKILLed (exit 137) while the stored binaries run
# fine, which made every check fail before it started. Resolving the stored binary directly is
# also stricter: the check runs EXACTLY the version aftman.toml pins, never a stray PATH copy.
#
# Usage (from a script that already cd'ed to the repo root):
#   source scripts/lib/tools.sh
#   ROJO="$(resolve_tool rojo)"; "$ROJO" --version
#
# resolve_tool <name>:
#   1. $<NAME>_BIN (e.g. LUAU_LSP_BIN) when set and executable — explicit override;
#   2. the aftman tool-storage binary of the version pinned in aftman.toml (owner matched
#      case-insensitively: the pin says "johnnymorganz", storage may say "JohnnyMorganz");
#   3. the first `<name>` on PATH (the shim) as a last resort.
#   Prints the path; returns 1 (with a message on stderr) when nothing is found.
# =============================================================================

resolve_tool() {
	local name="$1"
	local override_var
	override_var="$(printf '%s_BIN' "$name" | tr '[:lower:]-' '[:upper:]_')"
	local override="${!override_var:-}"
	if [[ -n "$override" && -x "$override" ]]; then
		printf '%s\n' "$override"
		return 0
	fi

	# Pin line looks like:  luau-lsp = "johnnymorganz/luau-lsp@1.70.1"
	local pin owner version storage owner_dir candidate
	pin="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" aftman.toml 2>/dev/null | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
	if [[ -n "$pin" && "$pin" == */*@* ]]; then
		owner="${pin%%/*}"
		version="${pin##*@}"
		storage="${HOME}/.aftman/tool-storage"
		if [[ -d "$storage" ]]; then
			owner_dir="$(find "$storage" -mindepth 1 -maxdepth 1 -type d -iname "$owner" 2>/dev/null | head -n 1)"
			if [[ -n "$owner_dir" ]]; then
				candidate="${owner_dir}/${name}/${version}/${name}"
				if [[ -x "$candidate" ]]; then
					printf '%s\n' "$candidate"
					return 0
				fi
			fi
		fi
	fi

	if command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
		return 0
	fi
	echo "[tools] ${name} not found (run \`aftman install\` in the repo root)" >&2
	return 1
}

# The version pinned in aftman.toml for <name> ("" when unpinned). Used by typecheck.sh to fetch
# Roblox type definitions that match the pinned luau-lsp exactly.
pinned_version() {
	local name="$1"
	grep -E "^[[:space:]]*${name}[[:space:]]*=" aftman.toml 2>/dev/null | head -n 1 | sed -E 's/.*@([^"]+)".*/\1/'
}
