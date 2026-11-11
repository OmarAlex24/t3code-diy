# Shared helpers for t3code-diy. Sourced by bin/t3code-diy, never executed.
# shellcheck shell=bash

DIY_HOME="${DIY_HOME:-$HOME/.t3code-diy}"
DIY_CONFIG="$DIY_HOME/config"

# Defaults. The config file written by `install` overrides any of them.
FORK_URL=""
FORK_BRANCH=""
UPSTREAM_URL="https://github.com/pingdotgg/t3code.git"
UPSTREAM_BRANCH="main"
FEED_PORT=47830
LABEL_PREFIX="dev.t3code-diy"
SCHEDULE_HOUR=5
SCHEDULE_MINUTE=0
RUN_AT_LOGIN=1
PUSH=1
# Who resolves rebase conflicts: claude (claude -p) or codex (codex exec). Empty model or effort =
# the CLI's default.
RESOLVER_PROVIDER="claude"
RESOLVER_MODEL="opus"
RESOLVER_EFFORT=""
RESOLVER_TIMEOUT_MIN=90
# When the rebase onto the newest upstream ends in conflicts the resolver can't settle: 1 builds the
# branch as it is, on the upstream it already contains; 0 fails the run (the app stays as it is).
FALLBACK_ON_CONFLICT=1
TOOL_PATH=""
# side-by-side: your build is its own app next to the official one (SIDE_* below).
# replace: your build takes over the official app's name, bundle id and data (switch/rollback).
MODE="side-by-side"
# The name upstream's build produces. In replace mode it is also the installed app's name.
APP_NAME="T3 Code (Nightly)"
APPS_DIR="/Applications"
OFFICIAL_BUNDLE_ID="com.t3tools.t3code"
SIDE_APP_NAME="T3 Code Custom"
SIDE_BUNDLE_ID="com.t3tools.t3code.custom"
SIDE_USER_DATA_NAME="t3code-custom"
SIDE_T3_HOME="$HOME/.t3-custom"
# The official app scans up from 3773, so a fixed port above that keeps the two apart.
SIDE_PORT=3873
# App icon: a 1024px PNG baked into each build. Relative paths are inside the repo being built.
# Empty keeps the stock icon. install sets the default below in side-by-side mode.
ICON=""
DEFAULT_SIDE_ICON="assets/dev/blueprint-macos-1024.png"
USERDATA_DIR="$HOME/.t3/userdata"
ELECTRON_DATA_DIRS=("$HOME/Library/Application Support/t3code-v2" "$HOME/Library/Application Support/t3code")
UPDATER_CACHE_DIR_NAME="t3code-diy-updater"
FORK_TEST_GROUPS=()
RUN_CHECK_CHANGED=1
KEEP_BUILDS=3
SEQ_START=900000
SIGNING_NAME="T3 Code DIY Local Signing"

load_config() {
  if [ ! -f "$DIY_CONFIG" ]; then
    echo "No config at $DIY_CONFIG. Run: t3code-diy install" >&2
    exit 1
  fi
  source_config
  derive_paths
  [ -n "$TOOL_PATH" ] && export PATH="$TOOL_PATH"
}

# Configs written before MODE existed were replace-mode installs; keep them that way.
# Configs from before RESOLVER_* had CLAUDE_MODEL/CLAUDE_TIMEOUT_MIN; those carry over.
source_config() {
  grep -q '^MODE=' "$DIY_CONFIG" || MODE="replace"
  local CLAUDE_MODEL="" CLAUDE_TIMEOUT_MIN=""
  # shellcheck disable=SC1090
  source "$DIY_CONFIG"
  if ! grep -q '^RESOLVER_PROVIDER=' "$DIY_CONFIG"; then
    RESOLVER_PROVIDER="claude"
    [ -n "$CLAUDE_MODEL" ] && RESOLVER_MODEL="$CLAUDE_MODEL"
    [ -n "$CLAUDE_TIMEOUT_MIN" ] && RESOLVER_TIMEOUT_MIN="$CLAUDE_TIMEOUT_MIN"
  fi
  return 0
}

# Model slugs as T3 Code shows them (opus, gpt-5.5, claude-opus-4-6[1m], openai/gpt-6.1-sol).
# Empty means the CLI's own default. Anything else is refused, so a value never reaches a shell.
RESOLVER_MODEL_RE='^[A-Za-z0-9][]A-Za-z0-9._:/[-]{0,127}$'
valid_resolver_provider() { case "$1" in claude | codex) return 0 ;; *) return 1 ;; esac; }
valid_resolver_model() { [ -z "$1" ] || [[ "$1" =~ $RESOLVER_MODEL_RE ]]; }
valid_resolver_timeout() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 5 ] && [ "$1" -le 600 ]; }

# Effort levels each CLI takes headless: claude --effort and codex's model_reasoning_effort.
# Workflow levels (Claude's ultracode, Codex's ultra) aren't effort for a one-shot rebase.
# T3 Code keeps the same lists as DIY_RESOLVER_EFFORTS (packages/contracts/src/diy.ts).
resolver_efforts() {
  case "$1" in
    claude) echo "low medium high xhigh max" ;;
    codex) echo "none minimal low medium high xhigh max" ;;
  esac
}
# valid_resolver_effort PROVIDER EFFORT; empty means the CLI's default and is always fine.
valid_resolver_effort() {
  [ -z "$2" ] && return 0
  case " $(resolver_efforts "$1") " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# Why the resolver CLI can't run right now (empty when it can). Needs TOOL_PATH on PATH.
resolver_problem() {
  case "$1" in
    claude)
      type -P claude >/dev/null || { echo "the claude CLI is not installed"; return; }
      claude auth status --json </dev/null 2>/dev/null | grep -q '"loggedIn": *true' \
        || echo "the claude CLI is not logged in (run: claude auth login)"
      ;;
    codex)
      type -P codex >/dev/null || { echo "the codex CLI is not installed"; return; }
      codex login status </dev/null >/dev/null 2>&1 || echo "the codex CLI is not logged in (run: codex login)"
      ;;
  esac
}

is_side_by_side() { [ "$MODE" = "side-by-side" ]; }

derive_paths() {
  REPO="$DIY_HOME/repo"
  UPSTREAM_WT="$DIY_HOME/upstream-check"
  FEED="$DIY_HOME/feed"
  BUILDS="$DIY_HOME/builds"
  LOGS="$DIY_HOME/logs"
  STATE="$DIY_HOME/state"
  BACKUPS="$DIY_HOME/backup"
  SIGNING="$DIY_HOME/signing"
  KEYCHAIN="$SIGNING/signing.keychain-db"
  ENTITLEMENTS="$SIGNING/entitlements.plist"
  KIT="$DIY_HOME/kit"
  FEED_URL="http://127.0.0.1:$FEED_PORT/"
  if is_side_by_side; then
    INSTALLED_NAME="$SIDE_APP_NAME"
    APP_BUNDLE_ID="$SIDE_BUNDLE_ID"
    INSTALLED_DB="$SIDE_T3_HOME/userdata/statev2.sqlite"
  else
    INSTALLED_NAME="$APP_NAME"
    APP_BUNDLE_ID="$OFFICIAL_BUNDLE_ID"
    INSTALLED_DB="$USERDATA_DIR/statev2.sqlite"
  fi
  INSTALLED_APP="$APPS_DIR/$INSTALLED_NAME.app"
  FEED_LABEL="$LABEL_PREFIX.feed"
  UPDATE_LABEL="$LABEL_PREFIX.update"
  AGENTS_DIR="${DIY_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
  FEED_PLIST="$AGENTS_DIR/$FEED_LABEL.plist"
  UPDATE_PLIST="$AGENTS_DIR/$UPDATE_LABEL.plist"
}

OPENSSL=/usr/bin/openssl
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { echo "error: $*" >&2; exit 1; }

notify() {
  local title="T3 Code DIY: $1" msg="$2"
  /usr/bin/osascript - "$title" "$msg" <<'EOF' >/dev/null 2>&1
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
}

# The signing identity's SHA-1, read from the cert so nothing is stored twice.
signing_identity() {
  "$OPENSSL" x509 -in "$SIGNING/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
}

unlock_signing_keychain() {
  security unlock-keychain -p "$(cat "$SIGNING/keychain.pass")" "$KEYCHAIN"
}

plist_version() {
  # PlistBuddy prints "File Doesn't Exist" on stdout, so check first.
  [ -f "$1/Contents/Info.plist" ] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# version_gt A B: true when A > B for the X.Y.Z-nightly.DATE.N format.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

expected_requirement() {
  printf 'identifier "%s" and certificate root = H"%s"' \
    "$APP_BUNDLE_ID" "$(signing_identity | tr 'A-F' 'a-f')"
}

is_fork_build() {
  [ -d "$1" ] && [ "$(designated_requirement "$1")" = "$(expected_requirement)" ]
}

# Re-signs every piece of code in the bundle, inside out, with the local identity, the hardened
# runtime and the non-restricted entitlements, then verifies the result strictly.
sign_app() {
  local app="$1" id
  id="$(signing_identity)"
  unlock_signing_keychain || return 1
  local cs=(codesign --force --timestamp=none --options runtime --entitlements "$ENTITLEMENTS"
    --keychain "$KEYCHAIN" -s "$id")

  # 1. Loose Mach-O files (executables, dylibs, native modules), deepest first.
  local f count=0
  while IFS= read -r f; do
    if file -b "$f" | grep -q 'Mach-O'; then
      "${cs[@]}" "$f" >/dev/null 2>&1 || { log "codesign failed: $f"; "${cs[@]}" "$f"; return 1; }
      count=$((count + 1))
    fi
  done < <(find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.node' -o -name '*.so' \) \
    | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
  log "signed $count Mach-O files"

  # 2. Nested bundles (frameworks, helper apps, XPC services), deepest first.
  local b
  while IFS= read -r b; do
    "${cs[@]}" "$b" >/dev/null 2>&1 || { log "codesign failed: $b"; "${cs[@]}" "$b"; return 1; }
  done < <(find "$app/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) \
    | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)

  # 3. The app itself.
  "${cs[@]}" "$app" || return 1
  codesign --verify --deep --strict --verbose=2 "$app"
}

# write_feed_yml <zip> <version> <out.yml>
write_feed_yml() {
  local zip="$1" version="$2" out="$3" name sha size
  name="$(basename "$zip")"
  sha="$("$OPENSSL" dgst -sha512 -binary "$zip" | base64)"
  size="$(stat -f %z "$zip")"
  cat >"$out.tmp" <<EOF
version: $version
files:
  - url: $name
    sha512: $sha
    size: $size
path: $name
sha512: $sha
releaseDate: '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
EOF
  mv -f "$out.tmp" "$out"
}

# Migrations declared at <ref> as "id name" lines.
migration_entries() {
  git -C "$REPO" show "$1:apps/server/src/persistence/Migrations.ts" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*\[([0-9]+), "([A-Za-z0-9_]+)".*/\1 \2/p'
}

# Prints all input lines except the last N.
all_but_last() { awk -v n="$1" '{ l[NR] = $0 } END { for (i = 1; i <= NR - n; i++) print l[i] }'; }

latest_build() {
  ls -1 "$BUILDS" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -1
}

# Regex-escapes a string for pgrep -x.
regex_escape() { printf %s "$1" | sed 's/[][().*^$+?{}|\\]/\\&/g'; }

# Blocks until T3 Code and anything holding its database are gone. With --yes it fails instead
# of waiting, because nobody is there to press Enter.
wait_for_app_quit() {
  local assume_yes="$1" db="$INSTALLED_DB" exe_re
  exe_re="$(regex_escape "$INSTALLED_APP/Contents/MacOS/$APP_NAME")"
  while lsof -t "$db" >/dev/null 2>&1 || pgrep -qfx "$exe_re"; do
    echo "Something still has T3 Code or $db open:"
    pgrep -lfx "$exe_re" | sed 's/^/  app: /'
    lsof "$db" 2>/dev/null | awk 'NR > 1 { print "  pid " $2 " " $1 }' | sort -u
    [ "$assume_yes" = 1 ] && die "quit it and run this again"
    read -r -p "Quit it and press Enter to check again (Ctrl+C aborts)... "
  done
}

# PIDs of anything running from inside the installed app bundle (read-only check, kills nothing).
installed_app_pids() {
  pgrep -f "^$(regex_escape "$INSTALLED_APP")/"
}

# True while an update run holds the lock.
update_running() {
  local pid
  pid="$(cat "$STATE/update.lock" 2>/dev/null)" && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

register_app() {
  # Only for the real /Applications; never register test copies with LaunchServices.
  [ "$APPS_DIR" = "/Applications" ] && "$LSREGISTER" -f "$1" || true
}

# Single-quotes a value for the config file (readable, unlike printf %q).
sq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }

write_config() {
  local tmp="$DIY_CONFIG.tmp" g v
  {
    echo "# t3code-diy config. Written by 'install'; edit freely, it is sourced by bash."
    for v in FORK_URL FORK_BRANCH UPSTREAM_URL UPSTREAM_BRANCH FEED_PORT LABEL_PREFIX \
      SCHEDULE_HOUR SCHEDULE_MINUTE RUN_AT_LOGIN; do
      echo "$v=$(sq "${!v}")"
    done
    echo "# 1 = push the rebased branch back to your fork (force-with-lease) after tests pass"
    echo "PUSH=$(sq "$PUSH")"
    echo "# Conflict resolver: claude or codex, the model and effort (empty = the CLI's default) and a"
    echo "# time limit. Effort: claude takes low, medium, high, xhigh, max; codex also none and minimal."
    echo "# 't3code-diy config set RESOLVER_PROVIDER codex RESOLVER_MODEL gpt-5.5' changes them."
    for v in RESOLVER_PROVIDER RESOLVER_MODEL RESOLVER_EFFORT RESOLVER_TIMEOUT_MIN; do echo "$v=$(sq "${!v}")"; done
    echo "# 1 = when the resolver can't settle the rebase, build the branch on the upstream it already"
    echo "# contains (behind upstream); 0 = fail the run and leave the installed app as it is"
    echo "FALLBACK_ON_CONFLICT=$(sq "$FALLBACK_ON_CONFLICT")"
    echo "# Your fork's tests: each entry is a regex over 'git ls-files', run as one 'vp test run'."
    printf 'FORK_TEST_GROUPS=('
    for g in "${FORK_TEST_GROUPS[@]+"${FORK_TEST_GROUPS[@]}"}"; do printf '\n  %s' "$(sq "$g")"; done
    printf '\n)\n'
    echo "RUN_CHECK_CHANGED=$(sq "$RUN_CHECK_CHANGED")"
    echo "# side-by-side: your build is its own app next to the official one (install-app)."
    echo "# replace: it takes over the official app (switch/rollback). See README, Modes."
    echo "MODE=$(sq "$MODE")"
    echo "# App icon: a 1024px PNG, baked into each build; after changing it run update --force."
    echo "# Relative paths are inside the repo being built. Empty keeps the stock icon."
    echo "ICON=$(sq "$ICON")"
    echo "# Side-by-side app. Baked into each build; after changing them run update --force,"
    echo "# then quit the app and run install-app."
    for v in SIDE_APP_NAME SIDE_BUNDLE_ID SIDE_USER_DATA_NAME SIDE_T3_HOME SIDE_PORT; do echo "$v=$(sq "${!v}")"; done
    echo "# The build's app name follows from the nightly version. Replace mode installs it under"
    echo "# that name and backs up USERDATA_DIR and ELECTRON_DATA_DIRS on switch."
    for v in APP_NAME APPS_DIR USERDATA_DIR; do echo "$v=$(sq "${!v}")"; done
    printf 'ELECTRON_DATA_DIRS=('
    for g in "${ELECTRON_DATA_DIRS[@]}"; do printf '\n  %s' "$(sq "$g")"; done
    printf '\n)\n'
    for v in UPDATER_CACHE_DIR_NAME KEEP_BUILDS SEQ_START; do echo "$v=$(sq "${!v}")"; done
    echo "# PATH for the launchd job (it does not read your shell profile). Re-running install"
    echo "# rebuilds it from your current shell unless you pass --tool-path."
    echo "TOOL_PATH=$(sq "$TOOL_PATH")"
  } >"$tmp"
  mv -f "$tmp" "$DIY_CONFIG"
}

# ---------------------------------------------------------------- time and JSON (bash 3.2, BSD date)
iso_colon() { sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
iso_now() { date +%Y-%m-%dT%H:%M:%S%z | iso_colon; }
iso_from_epoch() { date -j -f %s "$1" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null | iso_colon; }
# "2026-11-04 18:39:04" (the log's local time) or "20261104-183904" (a log's name) as ISO 8601.
iso_from_local() {
  local fmt='%Y-%m-%d %H:%M:%S'
  case "$1" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*) fmt='%Y%m%d-%H%M%S' ;; esac
  date -j -f "$fmt" "$1" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null | iso_colon
}

# A JSON string, or null for an empty value when the second argument is "null".
json_str() {
  local s="$1"
  if [ -z "$s" ] && [ "${2:-}" = null ]; then printf null; return; fi
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  printf '"%s"' "$(printf %s "$s" | tr -d '\000-\010\013\014\016-\037')"
}
json_bool() { if [ "$1" = 1 ]; then printf true; else printf false; fi; }
