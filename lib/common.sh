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
CLAUDE_MODEL="opus"
CLAUDE_TIMEOUT_MIN=90
TOOL_PATH=""
APP_NAME="T3 Code (Nightly)"
APPS_DIR="/Applications"
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
  # shellcheck disable=SC1090
  source "$DIY_CONFIG"
  derive_paths
  [ -n "$TOOL_PATH" ] && export PATH="$TOOL_PATH"
}

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
  INSTALLED_APP="$APPS_DIR/$APP_NAME.app"
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
  printf 'identifier "com.t3tools.t3code" and certificate root = H"%s"' \
    "$(signing_identity | tr 'A-F' 'a-f')"
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
  local assume_yes="$1" db="$USERDATA_DIR/statev2.sqlite" exe_re
  exe_re="$(regex_escape "$INSTALLED_APP/Contents/MacOS/$APP_NAME")"
  while lsof -t "$db" >/dev/null 2>&1 || pgrep -qfx "$exe_re"; do
    echo "Something still has T3 Code or $db open:"
    pgrep -lfx "$exe_re" | sed 's/^/  app: /'
    lsof "$db" 2>/dev/null | awk 'NR > 1 { print "  pid " $2 " " $1 }' | sort -u
    [ "$assume_yes" = 1 ] && die "quit it and run this again"
    read -r -p "Quit it and press Enter to check again (Ctrl+C aborts)... "
  done
}

register_app() {
  # Only for the real /Applications; never register test copies with LaunchServices.
  [ "$APPS_DIR" = "/Applications" ] && "$LSREGISTER" -f "$1" || true
}
