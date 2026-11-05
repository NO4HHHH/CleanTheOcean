#!/usr/bin/env bash
# Static check for src: luau-lsp analyze (types + lints) and a StyLua parse check.
#
#   tools/typecheck.sh            -> analyze output on stdout, parse errors on stderr
#
# luau-lsp needs three things to resolve this project:
#   - sourcemap.json  : regenerated from default.project.json each run, so require(script.Parent.X)
#                       and ReplicatedStorage.Shared.* resolve to real files
#   - Roblox globals  : tools/types/globalTypes.d.luau (from JohnnyMorganz/luau-lsp scripts/)
#   - base .luaurc    : the repo's own (empty) one
# Packages/ServerPackages are wally-vendored; their diagnostics are ignored, as are the vendored
# Madwork Replica* files and every .lua file under src.
#
# StyLua stdout is a reformat diff of the whole (unformatted) tree and is discarded: only its
# stderr is a parse error. Its exit code is 1 on every run and means nothing.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

LSP="$(ls /c/Users/bruce/.aftman/tool-storage/JohnnyMorganz/luau-lsp/*/luau-lsp.exe 2>/dev/null | sort -V | tail -1)"
STYLUA=/c/Users/bruce/.aftman/tool-storage/JohnnyMorganz/StyLua/0.18.1/StyLua.exe
DEFS=tools/types/globalTypes.d.luau

if [ -z "$LSP" ]; then echo "typecheck: luau-lsp.exe not found under aftman tool-storage" >&2; exit 2; fi
if [ ! -f "$DEFS" ]; then
	echo "typecheck: fetching $DEFS" >&2
	mkdir -p tools/types
	curl -sSfL -o "$DEFS" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau || exit 2
fi

rojo sourcemap default.project.json --output sourcemap.json >&2 || { echo "typecheck: rojo sourcemap failed" >&2; exit 2; }

echo "== luau-lsp analyze ($LSP) =="
"$LSP" analyze \
	--sourcemap=sourcemap.json \
	--definitions=@roblox="$DEFS" \
	--base-luaurc=.luaurc \
	--platform=roblox \
	--ignore="Packages/**" \
	--ignore="ServerPackages/**" \
	--ignore="**/_Index/**" \
	--ignore="src/shared/Utility/Replica*/**" \
	--ignore="**/*.lua" \
	src
LSP_EXIT=$?

echo "== StyLua parse check (stderr only) =="
"$STYLUA" --check src 2>&1 >/dev/null
echo "== done (luau-lsp exit $LSP_EXIT) =="
exit $LSP_EXIT
