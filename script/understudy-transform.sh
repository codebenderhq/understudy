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
# SINGLE model by design: the user is never offered a model choice —
# no picker entries to switch between, no other providers (whitelist +
# models.dev fetch disabled). Capability differences are enforced by the
# Worklyn proxy per billing tier, not by a client-side menu.
BAKED_CONFIG_JSON='{"enabled_providers":["worklyn"],"model":"worklyn/claude-sonnet-5","small_model":"worklyn/claude-sonnet-5","provider":{"worklyn":{"name":"Worklyn","npm":"@ai-sdk/anthropic","options":{"baseURL":"https://worklyn.me/v1"},"models":{"claude-sonnet-5":{"name":"Understudy","limit":{"context":200000,"output":32000},"tool_call":true}}}},"share":"disabled","autoupdate":false}'

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

# --- Desktop (Electron) anchors ---------------------------------------------
DESKPKG=packages/desktop/package.json
DESKCFG=packages/desktop/electron-builder.config.ts

assert_count "$DESKPKG" '"name": "@opencode-ai/desktop"'  1 'desktop package.json name'
assert_count "$DESKPKG" '"name": "OpenCode"'               1 'desktop package.json author.name (electron-builder company name)'
assert_count "$DESKCFG" 'dev: "ai.opencode.desktop.dev"'   1 'electron-builder APP_IDS.dev'
assert_count "$DESKCFG" 'beta: "ai.opencode.desktop.beta"' 1 'electron-builder APP_IDS.beta'
assert_count "$DESKCFG" 'prod: "ai.opencode.desktop"'      1 'electron-builder APP_IDS.prod'
assert_count "$DESKCFG" 'artifactName: "opencode-desktop-${os}-${arch}.${ext}"' 1 'electron-builder artifactName'
assert_count "$DESKCFG" 'productName: "OpenCode Dev"'      1 'electron-builder dev productName'
assert_count "$DESKCFG" 'productName: "OpenCode Beta"'     1 'electron-builder beta productName'
assert_count "$DESKCFG" 'productName: "OpenCode",'         1 'electron-builder prod productName'
assert_count "$DESKCFG" 'name: "OpenCode",'                2 'electron-builder protocol display names (base + prod)'
assert_count "$DESKCFG" 'name: "OpenCode Beta"'            1 'electron-builder beta protocol display name'
assert_count "$DESKCFG" 'publish: { provider: "github", owner: "anomalyco", repo: "opencode-beta", channel: "latest" }' 1 'electron-builder beta publish target'
assert_count "$DESKCFG" 'publish: { provider: "github", owner: "anomalyco", repo: "opencode", channel: "latest" }'      1 'electron-builder prod publish target'
assert_count "$DESKCFG" 'notarize: true'                   1 'electron-builder mac notarize flag'
assert_count "$DESKCFG" 'sign: true'                       1 'electron-builder dmg sign flag'
assert_count "$DESKCFG" 'fpm: [legacyDesktopEntryFpm]'     2 'electron-builder prod deb/rpm legacy desktop entry'
assert_count "$DESKCFG" 'packageName: "opencode-dev"'      1 'electron-builder dev rpm packageName'
assert_count "$DESKCFG" 'packageName: "opencode-beta"'     1 'electron-builder beta rpm packageName'
assert_count "$DESKCFG" 'packageName: "opencode",'         1 'electron-builder prod rpm packageName'

# TODO: packages/desktop/icons/{dev,beta,prod} are upstream's OpenCode icons —
# ship them as-is for now (no hand-drawn art); replace with understudy icons
# when we have real assets. NOTE: the opencode:// deep-link scheme is left
# untouched (internal, like OPENCODE_* env vars — renaming breaks app code).

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

# ---------------------------------------------------------------------------
# 3. Desktop (Electron) identity
# ---------------------------------------------------------------------------

# package.json: workspace name + author.name (electron-builder uses author as
# the company/maintainer identity).
jq '.name = "@understudy/desktop" | .author.name = "Understudy"' "$DESKPKG" > "$DESKPKG.tmp"
mv "$DESKPKG.tmp" "$DESKPKG"

# appIds per channel
replace_fixed "$DESKCFG" 'dev: "ai.opencode.desktop.dev"'   'dev: "worklyn.understudy.dev"'
replace_fixed "$DESKCFG" 'beta: "ai.opencode.desktop.beta"' 'beta: "worklyn.understudy.beta"'
replace_fixed "$DESKCFG" 'prod: "ai.opencode.desktop"'      'prod: "worklyn.understudy"'
# (linux executableName + StartupWMClass derive from the appId variable, so
# they follow automatically.)

# installer/updater artifact names
replace_fixed "$DESKCFG" 'artifactName: "opencode-desktop-${os}-${arch}.${ext}"' 'artifactName: "understudy-desktop-${os}-${arch}.${ext}"'

# product + protocol display names (the opencode:// scheme itself stays)
replace_fixed "$DESKCFG" 'productName: "OpenCode Dev"'  'productName: "Understudy Dev"'
replace_fixed "$DESKCFG" 'productName: "OpenCode Beta"' 'productName: "Understudy Beta"'
replace_fixed "$DESKCFG" 'productName: "OpenCode",'     'productName: "Understudy",'
replace_fixed "$DESKCFG" 'name: "OpenCode",'            'name: "Understudy",'
replace_fixed "$DESKCFG" 'name: "OpenCode Beta"'        'name: "Understudy Beta"'

# electron-updater feed: generic provider against Azure Blob. Both channels
# point at the same feed for now — only prod is built in CI.
UNDERSTUDY_FEED='publish: { provider: "generic", url: "https://worklynstore.blob.core.windows.net/store/understudy/latest", channel: "latest" }'
replace_fixed "$DESKCFG" 'publish: { provider: "github", owner: "anomalyco", repo: "opencode-beta", channel: "latest" }' "$UNDERSTUDY_FEED"
replace_fixed "$DESKCFG" 'publish: { provider: "github", owner: "anomalyco", repo: "opencode", channel: "latest" }'      "$UNDERSTUDY_FEED"

# unsigned/ad-hoc builds until we have signing identities (roadmap F11):
# no notarization, no dmg signing (CI also sets CSC_IDENTITY_AUTO_DISCOVERY=false).
replace_fixed "$DESKCFG" 'notarize: true' 'notarize: false'
replace_fixed "$DESKCFG" 'sign: true'     'sign: false'

# linux package identity: don't collide with upstream's opencode packages, and
# drop the opencode-desktop legacy launcher shim (meaningless for a fresh fork).
replace_fixed "$DESKCFG" 'packageName: "opencode-dev"'  'packageName: "understudy-dev"'
replace_fixed "$DESKCFG" 'packageName: "opencode-beta"' 'packageName: "understudy-beta"'
replace_fixed "$DESKCFG" 'packageName: "opencode",'     'packageName: "understudy",'
replace_fixed "$DESKCFG" 'fpm: [legacyDesktopEntryFpm]' 'fpm: []'

echo "understudy-transform: transforms applied"

# ── Icons: Understudy brand mark over upstream's icon tree ────────────────
# Generated by script/generate-icons.py from the-understudy-co mark.svg
# (ink triangle + channel-accent stage line: prod ochre / beta clay / dev
# indigo). Committed under assets/icons/; copied over packages/desktop/icons
# at build time so the upstream tree stays merge-clean.
for channel in prod beta dev; do
  [ -d "assets/icons/$channel" ] || { echo "understudy-transform: missing assets/icons/$channel (run script/generate-icons.py)"; exit 1; }
  [ -d "packages/desktop/icons/$channel" ] || { echo "understudy-transform: upstream moved packages/desktop/icons/$channel"; exit 1; }
  cp -R "assets/icons/$channel/." "packages/desktop/icons/$channel/"
done
echo "understudy-transform: icons applied"

# ── Cross-compile target filter ───────────────────────────────────────────
# build.ts only offers --single (native) or ALL targets. CI's windows leg
# cross-compiles from linux, so add an env filter: UNDERSTUDY_ONLY_OS /
# UNDERSTUDY_ONLY_ARCH select exactly one plain target (no baseline/abi
# variants). No-ops when the envs are unset.
BUILDTS="packages/opencode/script/build.ts"
assert_count "$BUILDTS" ': allTargets' 1
replace_fixed "$BUILDTS" ': allTargets' ': allTargets.filter((t) => !process.env.UNDERSTUDY_ONLY_OS || (t.os === process.env.UNDERSTUDY_ONLY_OS && t.arch === (process.env.UNDERSTUDY_ONLY_ARCH || t.arch) && t.avx2 !== false && t.abi === undefined))'
