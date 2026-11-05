# t3code-diy install: config, clone, signing identity and launchd jobs. Safe to re-run.
# shellcheck shell=bash

install_usage() {
  cat <<EOF
Usage: t3code-diy install [options]

Asks for anything you don't pass. With --yes it asks nothing and uses defaults.

  --fork-url URL          your fork (required), e.g. git@github.com:you/t3code.git
  --branch NAME           the branch with your changes (required)
  --upstream-url URL      default: $UPSTREAM_URL
  --upstream-branch NAME  default: $UPSTREAM_BRANCH
  --port N                local feed port, default: $FEED_PORT
  --hour H --minute M     daily run time, default: $SCHEDULE_HOUR:$(printf %02d "$SCHEDULE_MINUTE")
  --no-run-at-login       don't also run the update when you log in
  --model NAME            Claude model for conflicts, default: $CLAUDE_MODEL
  --label-prefix PREFIX   launchd label prefix, default: $LABEL_PREFIX
  --test-group REGEX      a group of your fork's tests (regex over git ls-files); repeatable
  --no-check-changed      skip upstream's "vp run check:changed" in the test gate
  --no-push               never push the rebased branch back to your fork
  --mode MODE             side-by-side (default): your build is its own app next to the
                          official one. replace: it takes over the official app (switch/rollback)
  --apps-dir DIR          default: $APPS_DIR
  --icon PNG              app icon, a 1024px PNG (relative paths are inside the repo being built).
                          Side-by-side default: $DEFAULT_SIDE_ICON (T3 Code Dev's
                          blueprint icon). Replace mode keeps the stock icon. --icon '' = stock

Side-by-side mode (re-run install-app after changing these):
  --side-name NAME        app name, default: "$SIDE_APP_NAME"
  --side-bundle-id ID     default: $SIDE_BUNDLE_ID
  --side-user-data NAME   Electron profile dir in ~/Library/Application Support, default: $SIDE_USER_DATA_NAME
  --side-home DIR         its T3 home (projects, threads, settings), default: $SIDE_T3_HOME
  --side-port N           its server port, default: $SIDE_PORT

Replace mode:
  --app-name NAME         default: "$APP_NAME"
  --userdata-dir DIR      default: $USERDATA_DIR
  --electron-data-dir DIR repeatable; default: the two t3code dirs in ~/Library/Application Support
  --tool-path PATH        PATH for the launchd job (default: built from where your tools live)
  --no-load               write the launchd plists but don't load them
  --yes                   no questions

DIY_HOME (default ~/.t3code-diy) decides where everything goes.
EOF
}

cmd_install() {
  local assume_yes=0 no_load=0 groups_set=0 edirs_set=0 tool_path_arg="" icon_set=0 had_icon=0 prev_mode
  local new_groups=() new_edirs=()
  # Re-running install keeps the existing answers as defaults.
  if [ -f "$DIY_CONFIG" ]; then
    source_config
    grep -q '^ICON=' "$DIY_CONFIG" && had_icon=1
  fi
  prev_mode="$MODE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --fork-url) FORK_URL="$2"; shift ;;
      --branch) FORK_BRANCH="$2"; shift ;;
      --upstream-url) UPSTREAM_URL="$2"; shift ;;
      --upstream-branch) UPSTREAM_BRANCH="$2"; shift ;;
      --port) FEED_PORT="$2"; shift ;;
      --hour) SCHEDULE_HOUR="$2"; shift ;;
      --minute) SCHEDULE_MINUTE="$2"; shift ;;
      --no-run-at-login) RUN_AT_LOGIN=0 ;;
      --model) CLAUDE_MODEL="$2"; shift ;;
      --label-prefix) LABEL_PREFIX="$2"; shift ;;
      --test-group) new_groups+=("$2"); groups_set=1; shift ;;
      --no-check-changed) RUN_CHECK_CHANGED=0 ;;
      --no-push) PUSH=0 ;;
      --mode) MODE="$2"; shift ;;
      --side-name) SIDE_APP_NAME="$2"; shift ;;
      --side-bundle-id) SIDE_BUNDLE_ID="$2"; shift ;;
      --side-user-data) SIDE_USER_DATA_NAME="$2"; shift ;;
      --side-home) SIDE_T3_HOME="$2"; shift ;;
      --side-port) SIDE_PORT="$2"; shift ;;
      --app-name) APP_NAME="$2"; shift ;;
      --apps-dir) APPS_DIR="$2"; shift ;;
      --icon) ICON="$2"; icon_set=1; shift ;;
      --userdata-dir) USERDATA_DIR="$2"; shift ;;
      --electron-data-dir) new_edirs+=("$2"); edirs_set=1; shift ;;
      --tool-path) tool_path_arg="$2"; shift ;;
      --no-load) no_load=1 ;;
      --yes | -y) assume_yes=1 ;;
      -h | --help) install_usage; return 0 ;;
      *) echo "unknown option: $1" >&2; install_usage >&2; return 2 ;;
    esac
    shift
  done
  [ "$groups_set" = 1 ] && FORK_TEST_GROUPS=("${new_groups[@]}")
  [ "$edirs_set" = 1 ] && ELECTRON_DATA_DIRS=("${new_edirs[@]}")
  [ -t 0 ] || assume_yes=1

  echo "t3code-diy install into $DIY_HOME"
  echo "(unofficial, not affiliated with T3 Tools)"
  echo
  check_prereqs || return 1

  if [ "$assume_yes" = 0 ]; then
    ask FORK_URL "Your fork's git URL"
    ask FORK_BRANCH "Branch with your changes"
    ask UPSTREAM_URL "Upstream URL"
    ask UPSTREAM_BRANCH "Upstream branch"
    ask FEED_PORT "Local feed port"
    ask SCHEDULE_HOUR "Daily run hour (0-23)"
    ask SCHEDULE_MINUTE "Daily run minute"
    ask CLAUDE_MODEL "Claude model for conflict resolution"
    if [ "${#FORK_TEST_GROUPS[@]}" = 0 ]; then
      echo "Your fork's own tests run before every build. Give a regex over 'git ls-files' per group,"
      echo "e.g. '^apps/server/src/myfeature/.*\.test\.ts$'. Empty line to finish."
      local g
      while read -r -p "  test group: " g && [ -n "$g" ]; do FORK_TEST_GROUPS+=("$g"); done
    fi
  fi
  [ -n "$FORK_URL" ] || die "--fork-url is required"
  [ -n "$FORK_BRANCH" ] || die "--branch is required"
  [[ "$FEED_PORT" =~ ^[0-9]+$ ]] || die "port must be a number"
  [[ "$SCHEDULE_HOUR" =~ ^[0-9]+$ && "$SCHEDULE_HOUR" -le 23 ]] || die "hour must be 0-23"
  [[ "$SCHEDULE_MINUTE" =~ ^[0-9]+$ && "$SCHEDULE_MINUTE" -le 59 ]] || die "minute must be 0-59"
  [[ "$LABEL_PREFIX" =~ ^[A-Za-z0-9.-]+$ ]] || die "label prefix may only use letters, digits, dots and dashes"
  case "$MODE" in side-by-side | replace) ;; *) die "--mode must be side-by-side or replace" ;; esac
  if is_side_by_side; then
    SIDE_T3_HOME="${SIDE_T3_HOME/#\~/$HOME}"
    [ -n "$SIDE_APP_NAME" ] && [[ "$SIDE_APP_NAME" != */* ]] || die "--side-name must be a plain name"
    [ "$SIDE_APP_NAME" != "$APP_NAME" ] && [ "$SIDE_APP_NAME" != "T3 Code" ] && [ "$SIDE_APP_NAME" != "T3 Code (Beta)" ] \
      || die "--side-name must differ from the official app names"
    [[ "$SIDE_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] && [ "$SIDE_BUNDLE_ID" != "$OFFICIAL_BUNDLE_ID" ] \
      || die "--side-bundle-id must be a reverse-DNS id other than $OFFICIAL_BUNDLE_ID"
    [[ "$SIDE_USER_DATA_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--side-user-data must be a plain directory name"
    case "$SIDE_USER_DATA_NAME" in t3code | t3code-v2 | t3code-dev) die "--side-user-data $SIDE_USER_DATA_NAME belongs to an official app" ;; esac
    case "$SIDE_T3_HOME" in /*) ;; *) die "--side-home must be an absolute path" ;; esac
    [ "${SIDE_T3_HOME%/}" != "$HOME/.t3" ] || die "--side-home must not be the official ~/.t3"
    [[ "$SIDE_PORT" =~ ^[0-9]+$ ]] && [ "$SIDE_PORT" -gt 1024 ] && [ "$SIDE_PORT" -le 65535 ] \
      || die "--side-port must be a port number above 1024"
    [ "$SIDE_PORT" != "$FEED_PORT" ] || die "--side-port and --port must differ"
    [ "$SIDE_PORT" != 3773 ] || die "--side-port 3773 is where the official app starts; pick another"
  fi
  # The icon follows the mode on a fresh config or a mode change, unless --icon says otherwise.
  # Side-by-side gets the blueprint icon so the two apps look different; replace keeps the stock one.
  if [ "$icon_set" = 0 ] && { [ "$had_icon" = 0 ] || [ "$prev_mode" != "$MODE" ]; }; then
    if is_side_by_side; then
      [ -n "$ICON" ] || ICON="$DEFAULT_SIDE_ICON"
    elif [ "$ICON" = "$DEFAULT_SIDE_ICON" ]; then
      ICON=""
    fi
  fi
  ICON="${ICON/#\~/$HOME}"

  TOOL_PATH="${tool_path_arg:-$(build_tool_path)}"
  derive_paths

  if lsof -nP -iTCP:"$FEED_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
    && ! launchctl print "gui/$(id -u)/$FEED_LABEL" >/dev/null 2>&1; then
    die "port $FEED_PORT is already in use; pick another with --port"
  fi

  # Reloading the launchd job would kill a run halfway through a rebase.
  update_running && die "an update is running (pid $(cat "$STATE/update.lock")); run install again when it's done"
  mkdir -p "$DIY_HOME" "$FEED" "$BUILDS" "$LOGS" "$STATE" "$BACKUPS"
  write_config
  echo "config: $DIY_CONFIG"
  copy_kit
  setup_repo || return 1
  setup_signing || return 1
  write_plists
  if [ "$no_load" = 0 ]; then
    load_agents
  else
    echo "launchd plists written (not loaded): $FEED_PLIST, $UPDATE_PLIST"
  fi

  cat <<EOF

Done.
- Command: $KIT/bin/t3code-diy (add $KIT/bin to your PATH if you like)
- Daily update at $SCHEDULE_HOUR:$(printf %02d "$SCHEDULE_MINUTE")$([ "$RUN_AT_LOGIN" = 1 ] && echo " and at login")$([ "$no_load" = 0 ] && [ "$RUN_AT_LOGIN" = 1 ] && echo "; the first one is running now")
- Logs: $LOGS (t3code-diy status shows the latest)
$(if is_side_by_side; then
  echo "- Mode: side-by-side. Once a build is in the feed, run \"t3code-diy install-app\" to put"
  echo "  \"$SIDE_APP_NAME\" in $APPS_DIR next to the official app."
else
  echo "- Mode: replace. Once a build is in the feed, run \"t3code-diy switch\" from Terminal.app."
fi)
EOF
}

ask() {
  local var="$1" prompt="$2" cur answer
  cur="${!var}"
  read -r -p "$prompt${cur:+ [$cur]}: " answer
  [ -n "$answer" ] && printf -v "$var" '%s' "$answer"
  return 0
}

check_prereqs() {
  local missing=0 v
  miss() { echo "  missing: $1"; echo "           $2"; missing=1; }
  echo "Checking prerequisites"
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || miss "macOS on Apple Silicon" "this kit only builds mac arm64"
  xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/codesign ] || miss "Xcode Command Line Tools" "xcode-select --install"
  type -P git >/dev/null || miss "git" "comes with the Command Line Tools: xcode-select --install"
  if v="$(type -P vp || find_vp)" && [ -n "$v" ]; then :; else
    miss "vp (Vite+), which T3 Code uses for installs and tests" "see https://viteplus.dev or T3 Code's CONTRIBUTING"
  fi
  if type -P node >/dev/null; then
    v="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
    [ "${v:-0}" -ge 22 ] || miss "node 22 or newer (found $(node -v))" "install the version in T3 Code's package.json engines (vp env can manage it)"
  else
    miss "node" "install the version in T3 Code's package.json engines (vp env can manage it)"
  fi
  if type -P cargo >/dev/null || [ -x "$HOME/.cargo/bin/cargo" ]; then
    local rustup; rustup="$(type -P rustup || echo "$HOME/.cargo/bin/rustup")"
    "$rustup" target list --installed 2>/dev/null | grep -qx aarch64-apple-darwin \
      || miss "Rust target aarch64-apple-darwin" "rustup target add aarch64-apple-darwin"
  else
    miss "Rust (cargo)" "install from https://rustup.rs, then: rustup target add aarch64-apple-darwin"
  fi
  if type -P claude >/dev/null; then
    claude auth status --json 2>/dev/null | grep -q '"loggedIn": *true' \
      || miss "Claude Code login" "run: claude auth login (or start claude once and log in)"
  else
    miss "Claude Code CLI (claude)" "see https://docs.claude.com/en/docs/claude-code"
  fi
  /usr/bin/python3 -c 'import http.server' >/dev/null 2>&1 || miss "/usr/bin/python3 (serves the local feed)" "comes with the Command Line Tools"
  for v in sqlite3 shlock ditto lsof; do type -P "$v" >/dev/null || miss "$v" "should ship with macOS"; done
  if [ "$missing" = 1 ]; then
    echo "Fix the above and run install again."
    return 1
  fi
  echo "  all good"
}

find_vp() {
  local d
  for d in "$HOME/.vite-plus/bin" "$HOME/.local/share/vite-plus/bin"; do
    [ -x "$d/vp" ] && { echo "$d/vp"; return 0; }
  done
  return 1
}

# A PATH for launchd jobs, which start with almost nothing. Shell-session dirs (fnm multishells)
# vanish, so node is resolved to its real install dir. claude keeps its symlink dir because its
# target changes with every auto-update.
build_tool_path() {
  local dirs=() t p r
  if p="$(type -P node)"; then
    r="$(realpath "$p")"
    if [ "$(basename "$r")" = node ]; then dirs+=("$(dirname "$r")"); else dirs+=("$(dirname "$p")"); fi
  fi
  p="$(type -P vp || find_vp)" && dirs+=("$(dirname "$p")")
  for t in cargo claude git pnpm gh; do
    p="$(type -P "$t")" && dirs+=("$(dirname "$p")")
  done
  [ -d "$HOME/.cargo/bin" ] && dirs+=("$HOME/.cargo/bin")
  dirs+=(/usr/bin /bin /usr/sbin /sbin)
  printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++' | paste -sd: -
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
    echo "CLAUDE_MODEL=$(sq "$CLAUDE_MODEL")"
    echo "CLAUDE_TIMEOUT_MIN=$(sq "$CLAUDE_TIMEOUT_MIN")"
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

copy_kit() {
  [ "$(cd "$KIT_SRC" && pwd -P)" = "$(mkdir -p "$KIT" && cd "$KIT" && pwd -P)" ] && return 0
  rm -rf "$KIT.tmp"; mkdir -p "$KIT.tmp"
  cp -R "$KIT_SRC/bin" "$KIT_SRC/lib" "$KIT_SRC/templates" "$KIT.tmp/"
  cp "$KIT_SRC/LICENSE" "$KIT_SRC/README.md" "$KIT.tmp/" 2>/dev/null
  rm -rf "$KIT"; mv "$KIT.tmp" "$KIT"
  chmod +x "$KIT/bin/t3code-diy"
  echo "kit copied to $KIT"
}

setup_repo() {
  export GIT_TERMINAL_PROMPT=0
  if [ -d "$REPO/.git" ]; then
    echo "repo exists: $REPO"
    git -C "$REPO" remote set-url origin "$FORK_URL"
  else
    echo "cloning $FORK_URL ($FORK_BRANCH) into $REPO"
    git clone --branch "$FORK_BRANCH" "$FORK_URL" "$REPO" || { echo "clone failed"; return 1; }
  fi
  if git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
    git -C "$REPO" remote set-url upstream "$UPSTREAM_URL"
  else
    git -C "$REPO" remote add upstream "$UPSTREAM_URL"
  fi
  git -C "$REPO" fetch -q upstream "$UPSTREAM_BRANCH" || { echo "cannot fetch $UPSTREAM_BRANCH from $UPSTREAM_URL"; return 1; }
  git -C "$REPO" config rerere.enabled true
  git -C "$REPO" config rerere.autoupdate true
  # T3 Connect needs the public Clerk/relay identifiers upstream ships in .env.example.
  if [ ! -f "$REPO/.env" ] && [ -f "$REPO/.env.example" ]; then
    cp "$REPO/.env.example" "$REPO/.env"
    echo "created $REPO/.env from .env.example"
  fi
}

# A self-signed code signing identity in its own keychain. The keychain stays out of your
# search list; codesign gets it with --keychain. Its password lives in a 0600 file.
setup_signing() {
  if [ -f "$SIGNING/cert.pem" ] && [ -f "$KEYCHAIN" ]; then
    echo "signing identity exists: $(signing_identity)"
    install_entitlements
    return 0
  fi
  echo "creating a self-signed signing identity in $KEYCHAIN"
  mkdir -p "$SIGNING"; chmod 700 "$SIGNING"
  (
    umask 077
    cd "$SIGNING" || exit 1
    head -c 32 /dev/urandom | base64 | tr -d '/+=' >keychain.pass
    head -c 32 /dev/urandom | base64 | tr -d '/+=' >p12.pass
    cat >cert.cnf <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGNING_NAME
O=$(id -un) local
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf \
      -keyout key.pem -out cert.pem 2>/dev/null || exit 1
    "$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -name "$SIGNING_NAME" \
      -out identity.p12 -passout file:p12.pass || exit 1
    rm -f key.pem
  ) || { echo "creating the certificate failed"; return 1; }

  local before=() k
  while IFS= read -r k; do before+=("$k"); done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')
  security create-keychain -p "$(cat "$SIGNING/keychain.pass")" "$KEYCHAIN" || return 1
  # create-keychain adds itself to the search list; put the list back as it was.
  if [ "${#before[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${before[@]}"
  else
    echo "warning: your keychain search list was empty; check it with: security list-keychains -d user"
  fi
  security set-keychain-settings "$KEYCHAIN"
  chmod 600 "$KEYCHAIN"
  unlock_signing_keychain || return 1
  security import "$SIGNING/identity.p12" -k "$KEYCHAIN" -P "$(cat "$SIGNING/p12.pass")" \
    -T /usr/bin/codesign >/dev/null || return 1
  # Lets codesign use the key without a GUI prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$(cat "$SIGNING/keychain.pass")" "$KEYCHAIN" >/dev/null || return 1
  security find-identity -p codesigning "$KEYCHAIN" | grep -q "$(signing_identity)" \
    || { echo "the identity did not land in $KEYCHAIN"; return 1; }
  echo "signing identity: $(signing_identity) (\"$SIGNING_NAME\")"
  install_entitlements
}

install_entitlements() {
  cp "$KIT_SRC/templates/entitlements.plist" "$ENTITLEMENTS"
}

xml_escape() { printf %s "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

write_plists() {
  mkdir -p "$AGENTS_DIR"
  local feed_x logs_x kit_x home_x
  feed_x="$(xml_escape "$FEED")"; logs_x="$(xml_escape "$LOGS")"
  kit_x="$(xml_escape "$KIT")"; home_x="$(xml_escape "$DIY_HOME")"
  cat >"$FEED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$FEED_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>-I</string>
    <string>-m</string>
    <string>http.server</string>
    <string>$FEED_PORT</string>
    <string>--bind</string>
    <string>127.0.0.1</string>
    <string>--directory</string>
    <string>$feed_x</string>
  </array>
  <key>WorkingDirectory</key><string>$feed_x</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$logs_x/feed-server.log</string>
  <key>StandardErrorPath</key><string>$logs_x/feed-server.log</string>
</dict>
</plist>
EOF
  cat >"$UPDATE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$UPDATE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$kit_x/bin/t3code-diy</string>
    <string>update</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DIY_HOME</key><string>$home_x</string>
  </dict>
  <key>WorkingDirectory</key><string>$home_x</string>
  <key>RunAtLoad</key>$([ "$RUN_AT_LOGIN" = 1 ] && echo "<true/>" || echo "<false/>")
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$SCHEDULE_HOUR</integer>
    <key>Minute</key><integer>$SCHEDULE_MINUTE</integer>
  </dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>5</integer>
  <key>StandardOutPath</key><string>$logs_x/launchd-update.log</string>
  <key>StandardErrorPath</key><string>$logs_x/launchd-update.log</string>
</dict>
</plist>
EOF
  plutil -lint -s "$FEED_PLIST" "$UPDATE_PLIST" || die "generated plists are invalid"
}

load_agents() {
  local uid label plist
  uid="$(id -u)"
  for label in "$FEED_LABEL" "$UPDATE_LABEL"; do
    plist="$AGENTS_DIR/$label.plist"
    launchctl bootout "gui/$uid/$label" 2>/dev/null
    launchctl bootstrap "gui/$uid" "$plist" || die "launchctl bootstrap failed for $plist"
    echo "loaded $label"
  done
  local i
  for i in $(seq 1 40); do
    curl -fsS -o /dev/null "$FEED_URL" 2>/dev/null && { echo "feed answering on $FEED_URL"; return 0; }
    sleep 0.5
  done
  echo "warning: the feed on $FEED_URL is not answering yet; see $LOGS/feed-server.log"
}
