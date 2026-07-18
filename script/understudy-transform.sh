#!/usr/bin/env bash
#
# understudy-transform.sh — build-time identity for the understudy fork.
#
# Strategy (see Worklyn roadmap: codebender-fork.md): the committed tree is
# upstream opencode + a tiny patch set. ALL rebranding happens here, at build
# time, so `git merge upstream/dev` stays trivial forever. Every transform is
# anchored: we grep-count the exact anchor string first and FAIL LOUDLY if
# upstream moved it — drift becomes a loud CI failure, never a silently wrong
# binary.
#
# Usage:
#   script/understudy-transform.sh              # assert anchors + apply transforms
#   script/understudy-transform.sh --check-only # assert anchors only (sync workflow)
#
# NOTE: applied transforms must never be committed. Run on a scratch checkout
# (CI) or discard with `git checkout -- . && git clean -f` locally.

set -euo pipefail

cd "$(dirname "$0")/.."

CHECK_ONLY=0
if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=1
fi

FAILED=0

# assert_count <file> <fixed-string-anchor> <expected-count> <description>
assert_count() {
  local file=$1 needle=$2 expected=$3 desc=$4
  local count
  if [[ ! -f "$file" ]]; then
    echo "FATAL: upstream moved the anchor: $desc — file $file no longer exists" >&2
    FAILED=1
    return
  fi
  count=$(grep -cF -- "$needle" "$file" || true)
  if [[ "$count" != "$expected" ]]; then
    echo "FATAL: upstream moved the anchor: $desc — expected $expected line(s) matching '$needle' in $file, found $count" >&2
    FAILED=1
  fi
}

# replace_fixed <file> <old-fixed-string> <new-fixed-string>  (portable, no sed -i quirks)
replace_fixed() {
  local file=$1 old=$2 new=$3
  OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# ---------------------------------------------------------------------------
# Baked config — the single source of truth for understudy's pinned provider.
# Anthropic wire format → bomba's /v1/messages; bomba maps x-api-key→Bearer
# and enforces tier model access server-side.
# ---------------------------------------------------------------------------
BAKED_CONFIG_JSON='{"enabled_providers":["worklyn"],"model":"worklyn/claude-sonnet-5","small_model":"worklyn/claude-sonnet-5","provider":{"worklyn":{"name":"Worklyn","npm":"@ai-sdk/anthropic","options":{"baseURL":"https://worklyn.me/v1"},"models":{"claude-sonnet-5":{"name":"Understudy (Sonnet 5)","limit":{"context":200000,"output":32000},"tool_call":true},"claude-opus-4-8":{"name":"Understudy Max (Opus 4.8)","limit":{"context":200000,"output":32000},"tool_call":true}}}},"share":"disabled","autoupdate":false}'

# ---------------------------------------------------------------------------
# 1. Anchor assertions (always run)
# ---------------------------------------------------------------------------
PKG=packages/opencode/package.json
WEBPKG=packages/web/package.json
BUILD=packages/opencode/script/build.ts
GLOBAL=packages/core/src/global.ts
INDEX=packages/opencode/src/index.ts
ATTENTION=packages/tui/src/attention.ts

assert_count "$PKG" '"name": "opencode"'                       1 'package.json name field'
assert_count "$PKG" '"opencode": "./bin/opencode"'             1 'package.json bin entry'
assert_count "$WEBPKG" '"opencode": "workspace:*"'             1 'web package.json workspace dep on the renamed package'
assert_count "$BUILD" 'bin/opencode'                           2 'build.ts compiled binary path (outfile + smoke test)'
assert_count "$BUILD" '--user-agent=opencode/'                 1 'build.ts user-agent execArgv'
assert_count "$BUILD" 'entrypoints: ["./src/index.ts",'        1 'build.ts entrypoints declaration'
assert_count "$GLOBAL" 'const app = "opencode"'                1 'global.ts XDG app name'
assert_count "$INDEX" '.scriptName("opencode")'                1 'index.ts yargs scriptName'
assert_count "$ATTENTION" 'const DEFAULT_TITLE = "opencode"'   1 'attention.ts terminal title'
# Baked-config env hooks must still exist upstream:
assert_count packages/core/src/flag/flag.ts 'OPENCODE_CONFIG_CONTENT: process.env["OPENCODE_CONFIG_CONTENT"]' 1 'flag.ts OPENCODE_CONFIG_CONTENT hook'
assert_count packages/core/src/flag/flag.ts 'OPENCODE_DISABLE_MODELS_FETCH: truthy("OPENCODE_DISABLE_MODELS_FETCH")' 1 'flag.ts OPENCODE_DISABLE_MODELS_FETCH hook'
assert_count packages/core/src/flag/flag.ts 'OPENCODE_DISABLE_AUTOUPDATE: truthy("OPENCODE_DISABLE_AUTOUPDATE")' 1 'flag.ts OPENCODE_DISABLE_AUTOUPDATE hook'

# TODO: packages/tui/src/logo.ts is block-drawn ASCII art ("opencode") — not
# trivially seddable to "understudy". Replace with a proper understudy logo
# later; the terminal title + scriptName already say understudy.

if [[ "$FAILED" == "1" ]]; then
  echo "understudy-transform: one or more anchors drifted. Fix the anchors (and transforms) before building." >&2
  exit 1
fi
echo "understudy-transform: all anchors OK"

if [[ "$CHECK_ONLY" == "1" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Transforms
# ---------------------------------------------------------------------------

# npm/binary identity
jq '.name = "understudy" | .bin = {"understudy": "./bin/understudy"}' "$PKG" > "$PKG.tmp"
mv "$PKG.tmp" "$PKG"
# keep workspace resolution intact after the rename (bun install fails otherwise)
replace_fixed "$WEBPKG" '"opencode": "workspace:*"' '"understudy": "workspace:*"'

# compiled binary path + smoke test + user-agent
replace_fixed "$BUILD" 'bin/opencode' 'bin/understudy'
replace_fixed "$BUILD" '--user-agent=opencode/' '--user-agent=understudy/'

# XDG dirs (~/.config/understudy, ~/.local/share/understudy, ...)
replace_fixed "$GLOBAL" 'const app = "opencode"' 'const app = "understudy"'

# yargs scriptName (help/usage text)
replace_fixed "$INDEX" '.scriptName("opencode")' '.scriptName("understudy")'

# terminal title
replace_fixed "$ATTENTION" 'const DEFAULT_TITLE = "opencode"' 'const DEFAULT_TITLE = "understudy"'

# wrapper entrypoint: bakes the pinned Worklyn config before importing the CLI
cat > packages/opencode/src/index.understudy.ts <<EOF
// Generated by script/understudy-transform.sh — build-time identity wrapper.
// DO NOT COMMIT. Sets understudy's baked config before the CLI (and the
// eagerly-evaluated Flag module) loads. \`??=\` keeps every env overridable.
process.env["OPENCODE_CONFIG_CONTENT"] ??= JSON.stringify($BAKED_CONFIG_JSON)
process.env["OPENCODE_DISABLE_MODELS_FETCH"] ??= "1"
process.env["OPENCODE_DISABLE_AUTOUPDATE"] ??= "1"
await import("./index.ts")
EOF

# point the build at the wrapper
replace_fixed "$BUILD" 'entrypoints: ["./src/index.ts",' 'entrypoints: ["./src/index.understudy.ts",'

echo "understudy-transform: transforms applied"
