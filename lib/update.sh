# t3code-diy update: rebase the fork on upstream, test, push, build, sign and publish to the feed.
# shellcheck shell=bash

update_usage() {
  cat <<EOF
Usage: t3code-diy update [--force] [--no-push] [--reuse-dist]

  --force       build even when nothing changed since the last build
  --no-push     do everything except pushing the rebased branch to your fork
  --reuse-dist  package the web/server output already built in the repo (quick rebuilds)

This is what the daily launchd job runs. Logs go to \$DIY_HOME/logs/update-*.log.
EOF
}

cmd_update() {
  local FORCE=0 NO_PUSH=0 REUSE_DIST=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=1 ;;
      --no-push) NO_PUSH=1 ;;
      --reuse-dist) REUSE_DIST=1 ;;
      -h | --help) update_usage; return 0 ;;
      *) echo "unknown option: $arg" >&2; update_usage >&2; return 2 ;;
    esac
  done
  load_config
  [ "$PUSH" = 1 ] || NO_PUSH=1
  mkdir -p "$FEED" "$BUILDS" "$LOGS" "$STATE"

  LOG="$LOGS/update-$(date +%Y%m%d-%H%M%S).log"
  echo "t3code-diy update: logging to $LOG" >&2
  if [ -t 1 ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
  # Keep the last 30 run logs.
  ls -1t "$LOGS"/update-*.log 2>/dev/null | tail -n +31 | while IFS= read -r old; do rm -f "$old"; done

  LOCK="$STATE/update.lock"
  if ! shlock -f "$LOCK" -p $$; then
    log "another run holds $LOCK (pid $(cat "$LOCK" 2>/dev/null)); exiting"
    exit 0
  fi
  RESOLVER_PID=""
  PATCHED=0
  STAGE="prepare"
  RUN_RESULT=""
  RUN_REASON=""
  RUN_VERSION=""
  RUN_STARTED="$(iso_now)"
  write_run_record running ""
  trap update_cleanup EXIT

  export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_TERMINAL_PROMPT=0
  # Browser tests need Playwright's Chromium. The kit keeps its own copy so cache cleaners can't
  # take it away between runs; run_gate downloads it when it's missing.
  export PLAYWRIGHT_BROWSERS_PATH="$DIY_HOME/playwright-browsers"
  cd "$REPO" || fail "repo missing: $REPO"

  log "== t3code-diy update start (mode=$MODE force=$FORCE no_push=$NO_PUSH reuse_dist=$REUSE_DIST)"
  log "fork: $FORK_URL ($FORK_BRANCH)  upstream: $UPSTREAM_URL ($UPSTREAM_BRANCH)"
  log "tools: node $(node -v 2>&1) ($(type -P node)), $(vp --version 2>&1 | head -1), $(cargo --version 2>&1), $RESOLVER_PROVIDER $("$RESOLVER_PROVIDER" --version 2>&1 | head -1)"

  # ------------------------------------------------------------ git: fetch & rebase
  rebase_in_progress && fail "a rebase is already in progress in $REPO; resolve or abort it by hand"
  restore_push_urls
  revert_leftover_side_patch
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes in $REPO; commit or discard them by hand"

  git fetch --prune upstream "$UPSTREAM_BRANCH" || fail "git fetch upstream failed"
  git fetch --prune origin "$FORK_BRANCH" || fail "git fetch origin failed"
  UP_REF="upstream/$UPSTREAM_BRANCH"
  ORIG="$(git rev-parse "origin/$FORK_BRANCH")"
  UP="$(git rev-parse "$UP_REF")"
  log "origin/$FORK_BRANCH=$ORIG $UP_REF=$UP"

  git checkout -q -B "$FORK_BRANCH" "$ORIG" || fail "checkout failed"

  # The fork's migrations must sort after every upstream migration. If upstream reused one of the
  # fork's ids, renumbering would break any database the fork already migrated (the migrator
  # refuses a history whose names differ under the highest recorded id). A human decides that.
  MB="$(git merge-base "$ORIG" "$UP")"
  local up_max id name
  up_max="$(migration_entries "$UP" | awk '{print $1}' | sort -n | tail -1)"
  while read -r id name; do
    [ -z "$id" ] && continue
    migration_entries "$UP" | grep -qx "$id $name" && continue
    if [ "$id" -le "${up_max:-0}" ]; then
      RUN_RESULT=migration_collision
      fail "migration collision: upstream migration ids now reach $up_max and collide with your fork's migration $id $name. Renumbering is unsafe; decide by hand (see README, Caveats)"
    fi
  done < <(comm -13 <(migration_entries "$MB" | sort) <(migration_entries "$ORIG" | sort))

  RR_BEFORE="$(ls -1 .git/rr-cache 2>/dev/null | sort)"
  REBASED=0
  STAGE="rebase"
  if git merge-base --is-ancestor "$UP" "$ORIG"; then
    log "branch already contains $UP_REF; no rebase needed"
  else
    log "rebasing $(git rev-list --count "$MB..$ORIG") fork commits onto $UP_REF ($(git rev-list --count "$MB..$UP") new upstream commits)"
    REBASED=1
    git rebase "$UP_REF"
    local used_resolver=0 unresolved
    while rebase_in_progress; do
      unresolved="$(git diff --name-only --diff-filter=U)"
      if [ -z "$unresolved" ] && [ "$used_resolver" = 0 ]; then
        log "conflicts resolved by rerere; continuing"
        git add -u && git rebase --continue && continue
      fi
      [ "$used_resolver" = 1 ] && break
      log "conflicts in: $(echo "$unresolved" | tr '\n' ' ')"
      used_resolver=1
      run_resolver
    done
    if rebase_in_progress; then
      restore_branch
      RUN_RESULT=conflict_unresolved
      fail "$(resolver_label) could not resolve the rebase conflicts in $(echo "$unresolved" | wc -l | tr -d ' ') file(s)"
    fi
    git merge-base --is-ancestor "$UP" HEAD || { restore_branch; fail "rebase result does not contain $UP_REF"; }
    [ -z "$(git status --porcelain --untracked-files=no)" ] || { restore_branch; fail "rebase left uncommitted changes"; }
    local dup
    dup="$(migration_entries HEAD | awk '{print $1}' | sort | uniq -d)"
    [ -z "$dup" ] || { restore_branch; RUN_RESULT=migration_collision; fail "duplicate migration ids after rebase: $dup"; }
  fi
  HEAD_SHA="$(git rev-parse HEAD)"
  log "result HEAD=$HEAD_SHA ($(git rev-list --count "$UP..HEAD") commits on top of upstream)"

  if [ "$HEAD_SHA" = "$(cat "$STATE/last-built-sha" 2>/dev/null)" ] && [ "$FORCE" = 0 ]; then
    log "nothing changed since the last build ($HEAD_SHA); done"
    RUN_RESULT=up_to_date
    RUN_REASON="nothing changed since the last build"
    RUN_VERSION="$(cat "$STATE/last-version" 2>/dev/null)"
    exit 0
  fi

  # ------------------------------------------------------------ tests
  STAGE="tests"
  if ! run_gate; then
    if [ "$REBASED" = 1 ]; then
      log "tests failed after rebase; restoring $FORK_BRANCH to $ORIG"
      restore_branch
      vp i >/dev/null 2>&1
    fi
    fail "$(cat "$STATE/gate-reason" 2>/dev/null || echo "the tests failed")"
  fi
  log "tests green"
  STAGE="push"

  # ------------------------------------------------------------ push
  if [ "$HEAD_SHA" != "$ORIG" ]; then
    if [ "$NO_PUSH" = 1 ]; then
      log "skipping push"
    else
      git push --force-with-lease="$FORK_BRANCH:$ORIG" origin "HEAD:$FORK_BRANCH" \
        || fail "push to origin failed (someone pushed in between?)"
      log "pushed $HEAD_SHA to origin/$FORK_BRANCH"
    fi
  fi

  # ------------------------------------------------------------ version
  STAGE="build"
  local desktop_version base seq version last_version installed
  desktop_version="$(node -p 'require("./apps/desktop/package.json").version')" || fail "cannot read the desktop version"
  base="$(echo "$desktop_version" | sed -E 's/[-+].*//' | awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}')"
  seq=$(($(cat "$STATE/build-seq" 2>/dev/null || echo "$SEQ_START") + 1))
  version="$base-nightly.$(date -u +%Y%m%d).$seq"
  last_version="$(cat "$STATE/last-version" 2>/dev/null)"
  if [ -n "$last_version" ] && ! version_gt "$version" "$last_version"; then
    fail "computed version $version is not above the last build $last_version"
  fi
  installed="$(plist_version "$INSTALLED_APP")"
  if [ -n "$installed" ] && ! version_gt "$version" "$installed"; then
    fail "computed version $version is not above the installed $installed"
  fi
  log "building version $version (installed: ${installed:-none}, last build: ${last_version:-none})"

  # ------------------------------------------------------------ build
  if is_side_by_side; then
    case "$SIDE_T3_HOME" in /*) ;; *) fail "SIDE_T3_HOME must be an absolute path (got '$SIDE_T3_HOME')" ;; esac
    apply_side_patch
  fi
  local work="$BUILDS/.work" build_args built_app apps
  rm -rf "$work"
  build_args=(--platform mac --target dir --arch arm64 --build-version "$version" --output-dir "$work")
  [ "$REUSE_DIST" = 1 ] && build_args+=(--skip-build)
  # No signing identity and no publish config: the app is re-signed and its feed written below.
  CSC_IDENTITY_AUTO_DISCOVERY=false node scripts/build-desktop-artifact.ts "${build_args[@]}" || fail "desktop build failed"
  revert_side_patch
  apps=()
  while IFS= read -r built_app; do apps+=("$built_app"); done < <(find "$work/mac-arm64" -maxdepth 1 -name '*.app' 2>/dev/null)
  [ "${#apps[@]}" = 1 ] || fail "expected one .app in $work/mac-arm64, found ${#apps[@]}"
  built_app="${apps[0]}"
  [ "$(basename "$built_app")" = "$APP_NAME.app" ] \
    || fail "the build produced '$(basename "$built_app")' but APP_NAME is '$APP_NAME'; fix APP_NAME in $DIY_CONFIG"
  [ "$(plist_version "$built_app")" = "$version" ] || fail "built app version is $(plist_version "$built_app"), expected $version"

  if is_side_by_side; then
    # Without the override the app would use the official profile, lose the single-instance lock
    # to the official app and quit. Never publish that.
    grep -qa T3CODE_DESKTOP_USER_DATA_NAME "$built_app/Contents/Resources/app.asar" \
      || fail "the built app does not read T3CODE_DESKTOP_USER_DATA_NAME (stale --reuse-dist output?); not publishing it"
    built_app="$(make_side_by_side "$built_app")" || fail "turning the build into $SIDE_APP_NAME failed"
    log "side-by-side app: $SIDE_APP_NAME ($SIDE_BUNDLE_ID), home $SIDE_T3_HOME, userData $SIDE_USER_DATA_NAME, port $SIDE_PORT"
  fi

  # The managed policy's feedUrl only accepts https, so the local feed is baked into the bundle.
  cat >"$built_app/Contents/Resources/app-update.yml" <<EOF
provider: generic
url: $FEED_URL
channel: nightly
updaterCacheDirName: $UPDATER_CACHE_DIR_NAME
EOF

  apply_icon "$built_app"
  apply_diy_env "$built_app" || fail "writing the kit's keys into Info.plist failed"

  log "signing"
  sign_app "$built_app" || fail "signing failed"
  local dr
  dr="$(designated_requirement "$built_app")"
  [ "$dr" = "$(expected_requirement)" ] || fail "unexpected designated requirement: $dr"
  log "designated requirement: $dr"

  local dest="$BUILDS/$version"
  rm -rf "$dest"; mkdir -p "$dest"
  mv "$built_app" "$dest/"
  echo "$HEAD_SHA" >"$dest/commit"
  echo "$MODE" >"$dest/mode"
  echo "$UP" >"$dest/upstream-commit"
  rm -rf "$work"

  # ------------------------------------------------------------ publish
  local zip_name="T3-Code-$version-arm64.zip"
  (cd "$dest" && ditto -c -k --keepParent "$INSTALLED_NAME.app" "$FEED/.$zip_name.part") || fail "zip failed"
  mv -f "$FEED/.$zip_name.part" "$FEED/$zip_name"
  # The app reads nightly-mac.yml on the nightly channel; latest-mac.yml covers the stable one.
  write_feed_yml "$FEED/$zip_name" "$version" "$FEED/nightly-mac.yml"
  cp -f "$FEED/nightly-mac.yml" "$FEED/latest-mac.yml"
  log "published $zip_name ($(stat -f %z "$FEED/$zip_name") bytes) to $FEED"

  echo "$HEAD_SHA" >"$STATE/last-built-sha"
  echo "$version" >"$STATE/last-version"
  echo "$seq" >"$STATE/build-seq"
  RUN_VERSION="$version"

  # ------------------------------------------------------------ prune
  local old
  ls -1 "$BUILDS" | grep -E '^[0-9]' | sort -V | all_but_last "$KEEP_BUILDS" | while read -r old; do
    log "pruning build $old"; rm -rf "${BUILDS:?}/$old"
  done
  ls -1 "$FEED"/T3-Code-*-arm64.zip 2>/dev/null | sort -V | all_but_last "$KEEP_BUILDS" | while read -r old; do
    log "pruning feed $(basename "$old")"; rm -f "$old"
  done

  log "== done: $version"
  RUN_RESULT=ok
  RUN_REASON="built $version"
  if [ -d "$INSTALLED_APP" ]; then
    notify "build ready" "$version is in the local feed. Use Check for updates in $INSTALLED_NAME." && log "notification sent"
  else
    notify "build ready" "$version is ready. Install it with: t3code-diy $(is_side_by_side && echo install-app || echo switch)" && log "notification sent"
  fi
  exit 0
}

update_cleanup() {
  local rc=$?
  [ -n "${RESOLVER_PID:-}" ] && kill -- "-$RESOLVER_PID" 2>/dev/null
  restore_push_urls
  revert_side_patch
  if [ -z "$RUN_RESULT" ]; then
    RUN_RESULT=error
    RUN_REASON="the run stopped unexpectedly during the $STAGE step (exit $rc)"
  fi
  write_run_record "$RUN_RESULT" "$(iso_now)"
  rm -f "$LOCK"
}

# state/last-run: what the last run did, for status --json. key=value lines, read with sed, never sourced.
write_run_record() {
  local result="$1" ended="$2"
  {
    echo "pid=$$"
    echo "started_at=$RUN_STARTED"
    echo "ended_at=$ended"
    echo "result=$result"
    echo "reason=$(printf %s "$RUN_REASON" | tr '\n\t' '  ')"
    echo "version=$RUN_VERSION"
    echo "log=$LOG"
  } >"$STATE/last-run.tmp" && mv -f "$STATE/last-run.tmp" "$STATE/last-run"
}

# Both kinds of builds get these; the app reads T3CODE_DIY_BIN to find the kit (Settings, About),
# and a side-by-side app shows its own name instead of "T3 Code (Nightly)". Must run before signing.
apply_diy_env() {
  local p="$1/Contents/Info.plist" bin="$KIT/bin/t3code-diy"
  [ -x "$bin" ] || bin="$KIT_SRC/bin/t3code-diy"
  plutil -extract LSEnvironment raw "$p" >/dev/null 2>&1 || plutil -insert LSEnvironment -dictionary "$p" || return 1
  plutil -replace LSEnvironment.T3CODE_DIY_BIN -string "$bin" "$p" || return 1
  if is_side_by_side; then
    plutil -replace LSEnvironment.T3CODE_DESKTOP_DISPLAY_NAME -string "$SIDE_APP_NAME" "$p" || return 1
  fi
  plutil -lint -s "$p" || return 1
  log "Info.plist: T3CODE_DIY_BIN=$bin$(is_side_by_side && echo ", T3CODE_DESKTOP_DISPLAY_NAME=$SIDE_APP_NAME")"
}

# ---------------------------------------------------------------- side-by-side
# Upstream hardcodes the Electron profile dir (t3code-v2), so two apps would share one profile
# and one single-instance lock. This small patch lets T3CODE_DESKTOP_USER_DATA_NAME pick another.
# It is applied only for the build, after the tests and the push, and reverted right after.
SIDE_PATCH_FILE="apps/desktop/src/app/DesktopUserData.ts"
side_patch() { echo "$KIT_SRC/templates/patches/userdata-name.patch"; }

apply_side_patch() {
  if grep -q T3CODE_DESKTOP_USER_DATA_NAME "$REPO/$SIDE_PATCH_FILE"; then
    log "$SIDE_PATCH_FILE already reads T3CODE_DESKTOP_USER_DATA_NAME; no patch needed"
    return 0
  fi
  git -C "$REPO" apply --check "$(side_patch)" \
    || fail "the side-by-side patch no longer applies to $SIDE_PATCH_FILE (upstream changed it), so nothing was built. Update $(side_patch)"
  git -C "$REPO" apply "$(side_patch)" || fail "applying the side-by-side patch failed"
  PATCHED=1
  [ "$(git -C "$REPO" diff --numstat)" = "$(printf '3\t0\t%s' "$SIDE_PATCH_FILE")" ] \
    || fail "the side-by-side patch did not apply exactly: $(git -C "$REPO" diff --numstat | tr '\n' ' ')"
  log "applied the side-by-side patch to $SIDE_PATCH_FILE"
}

revert_side_patch() {
  [ "${PATCHED:-0}" = 1 ] || return 0
  if git -C "$REPO" apply -R "$(side_patch)"; then
    PATCHED=0
    log "reverted the side-by-side patch"
  else
    log "could not revert the side-by-side patch; the next run retries"
  fi
}

# A run killed mid-build leaves the patch in the tree; take it out so the tree is clean again.
revert_leftover_side_patch() {
  [ "$(git diff --numstat)" = "$(printf '3\t0\t%s' "$SIDE_PATCH_FILE")" ] || return 0
  git apply -R --check "$(side_patch)" 2>/dev/null || return 0
  git apply -R "$(side_patch)" && log "reverted the side-by-side patch a previous run left behind"
}

# Renames the built app the way electron-builder would for another productName (main executable,
# helper apps, their Info.plists), gives it its own bundle id, and bakes its home, profile and
# port into LSEnvironment so Finder, the Dock and the updater's relaunch all start it the same way.
# Prints the new path. Must run before signing.
make_side_by_side() {
  local app="$1" from="$APP_NAME" to="$SIDE_APP_NAME" c h suffix nh hp id
  c="$app/Contents"
  [ -f "$c/MacOS/$from" ] || { log "no executable $c/MacOS/$from" >&2; return 1; }
  mv "$c/MacOS/$from" "$c/MacOS/$to" || return 1
  for h in "$c/Frameworks/$from Helper"*.app; do
    [ -d "$h" ] || continue
    suffix="$(basename "$h" .app)"; suffix="${suffix#"$from Helper"}"
    nh="$c/Frameworks/$to Helper$suffix.app"
    mv "$h" "$nh" || return 1
    mv "$nh/Contents/MacOS/$from Helper$suffix" "$nh/Contents/MacOS/$to Helper$suffix" || return 1
    hp="$nh/Contents/Info.plist"
    id="$(plutil -extract CFBundleIdentifier raw "$hp")" || return 1
    plutil -replace CFBundleExecutable -string "$to Helper$suffix" "$hp" || return 1
    plutil -replace CFBundleDisplayName -string "$to Helper$suffix" "$hp" || return 1
    plutil -replace CFBundleIdentifier -string "$SIDE_BUNDLE_ID${id#"$OFFICIAL_BUNDLE_ID"}" "$hp" || return 1
  done
  [ -z "$(find "$c" -name "*$from*")" ] || { log "leftover '$from' paths: $(find "$c" -name "*$from*")" >&2; return 1; }
  local p="$c/Info.plist" k
  for k in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    plutil -replace "$k" -string "$to" "$p" || return 1
  done
  plutil -replace CFBundleIdentifier -string "$SIDE_BUNDLE_ID" "$p" || return 1
  plutil -extract LSEnvironment raw "$p" >/dev/null 2>&1 || plutil -insert LSEnvironment -dictionary "$p" || return 1
  plutil -replace LSEnvironment.T3CODE_HOME -string "$SIDE_T3_HOME" "$p" || return 1
  plutil -replace LSEnvironment.T3CODE_DESKTOP_USER_DATA_NAME -string "$SIDE_USER_DATA_NAME" "$p" || return 1
  plutil -replace LSEnvironment.T3CODE_PORT -string "$SIDE_PORT" "$p" || return 1
  plutil -lint -s "$p" "$c/Frameworks/$to Helper"*.app/Contents/Info.plist || return 1
  mv "$app" "$(dirname "$app")/$to.app" || return 1
  echo "$(dirname "$app")/$to.app"
}

# Replaces the bundle's icon.icns and icon.png with ICON (a 1024px PNG). Must run before signing.
# A missing or unconvertible ICON only logs: the build goes on with the stock icon.
apply_icon() {
  local res="$1/Contents/Resources" src="$ICON" tmp size
  [ -n "$src" ] || return 0
  case "$src" in /*) ;; *) src="$REPO/$src" ;; esac
  if [ ! -f "$src" ]; then
    log "icon $src not found; keeping the stock icon"
    return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/t3code-diy-icon.XXXXXX")" || { log "no temp dir for the icon; keeping the stock icon"; return 0; }
  # Render everything first so a failure halfway leaves the stock icon intact.
  if (
    mkdir "$tmp/icon.iconset" || exit 1
    for size in 16 32 128 256 512; do
      sips -s format png -z "$size" "$size" "$src" --out "$tmp/icon.iconset/icon_${size}x${size}.png" >/dev/null || exit 1
      sips -s format png -z $((size * 2)) $((size * 2)) "$src" --out "$tmp/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null || exit 1
    done
    iconutil -c icns "$tmp/icon.iconset" -o "$tmp/icon.icns" || exit 1
    sips -s format png -z 512 512 "$src" --out "$tmp/icon.png" >/dev/null || exit 1
  ); then
    if cp -f "$tmp/icon.icns" "$tmp/icon.png" "$res/"; then
      log "icon: $src"
    else
      log "copying the icon into $res failed"
    fi
  else
    log "could not turn $src into an icon; keeping the stock icon"
  fi
  rm -rf "$tmp"
}

# fail <reason>: RUN_RESULT, when the caller set one, names the failure; otherwise the step does.
fail() {
  if [ -z "$RUN_RESULT" ]; then
    case "$STAGE" in
      rebase) RUN_RESULT=rebase_failed ;;
      tests) RUN_RESULT=tests_failed ;;
      push) RUN_RESULT=push_failed ;;
      build) RUN_RESULT=build_failed ;;
      *) RUN_RESULT=error ;;
    esac
  fi
  RUN_REASON="$*"
  log "FAILED ($RUN_RESULT): $*"
  notify "update failed" "$*. The installed app is unchanged. (log: $LOG)" && log "notification sent"
  exit 1
}

rebase_in_progress() { [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; }

restore_branch() {
  rebase_in_progress && git rebase --abort
  git checkout -q -f -B "$FORK_BRANCH" "$ORIG"
  # Forget resolutions recorded during this failed run so they do not replay tomorrow.
  local e
  comm -13 <(printf '%s\n' "$RR_BEFORE") <(ls -1 .git/rr-cache 2>/dev/null | sort) \
    | while read -r e; do [ -n "$e" ] && rm -rf ".git/rr-cache/$e"; done
  log "restored $FORK_BRANCH to $ORIG"
}

# Files of one FORK_TEST_GROUPS entry (an extended regex over `git ls-files`).
group_files() { git ls-files | grep -E "$1" | tr '\n' ' '; }

# Says in one line why the gate failed (for the run record) and fails.
gate_fail() { echo "$1" >"$STATE/gate-reason"; return 1; }

run_gate() {
  rm -f "$STATE/gate-reason"
  log "vp i"
  vp i || gate_fail "installing dependencies (vp i) failed" || return 1
  # Same step as upstream's CI. Quick when the right version is already there.
  local pw="$REPO/apps/web/node_modules/playwright/cli.js"
  if [ -f "$pw" ]; then
    log "playwright: chromium headless shell in $PLAYWRIGHT_BROWSERS_PATH"
    node "$pw" install --only-shell chromium \
      || gate_fail "downloading Playwright's Chromium for the browser tests failed" || return 1
  fi
  local group files
  for group in "${FORK_TEST_GROUPS[@]+"${FORK_TEST_GROUPS[@]}"}"; do
    files="$(group_files "$group")"
    [ -n "$files" ] || { log "test group '$group' matches no files"; gate_fail "the test group '$group' matches no files"; return 1; }
    log "fork tests ($group): $files"
    # shellcheck disable=SC2086
    vp test run $files || gate_fail "your fork's tests failed ($(echo "$files" | wc -w | tr -d ' ') file(s) in '$group')" || return 1
  done
  [ "$RUN_CHECK_CHANGED" = 1 ] || return 0
  log "vp run check:changed $UP_REF"
  local out="$STATE/check-changed.out"
  vp run check:changed "$UP_REF" 2>&1 | tee "$out"
  [ "${PIPESTATUS[0]}" = 0 ] && return 0
  # Only test steps may fail, and only with failures plain upstream has too.
  local bad
  bad="$(sed $'s/\x1b\\[[0-9;]*m//g' "$out" | sed -n '/check:changed summary/,$p' \
    | sed -nE 's/^ *(FAIL|TIMEOUT) +(.+) [0-9.]+s$/\1 \2/p' | grep -vE '^FAIL test( |$)')"
  if [ -n "$bad" ]; then log "check:changed failed: $bad"; gate_fail "check:changed failed: $(echo "$bad" | sed 's/^FAIL //' | paste -sd, - | sed 's/,/, /g')"; return 1; fi
  failures_are_preexisting "$out"
}

# "file > suite > test" for every failed test in vitest output. Vitest prints the project as
# "|name|" without colors and as a colored badge with them (launchd runs get colors), so both
# forms are accepted once the escape codes are gone. Browser projects add "(browser) (chromium)".
failed_tests() {
  sed $'s/\x1b\\[[0-9;]*m//g' "$1" \
    | sed -nE 's/^ FAIL +(\|[^|]*\| +|[^ ]+( \([^)]*\))* +)?([^ ]+\.(test|spec)\.[cm]?[jt]sx?( > .*)?)$/\3/p' \
    | sort -u
}

# Re-runs the failing test files on a pristine upstream checkout; succeeds only when every
# failure reported for the fork also fails there (pre-existing upstream failures).
failures_are_preexisting() {
  local out="$1" lines files f path up_lines missing
  lines="$(failed_tests "$out")"
  [ -n "$lines" ] || { log "check:changed failed without test failures I can parse"; gate_fail "check:changed failed"; return 1; }
  # A browser test that lost its session to another Playwright run passes when re-run alone.
  files="$(echo "$lines" | sed -E 's/ > .*//; s/ \[.*//' | sort -u)"
  : >"$STATE/fork-retest.out"
  while IFS= read -r f; do
    path="$(git -C "$REPO" ls-files | grep -E "(^|/)${f//./\\.}$" | tr '\n' ' ')"
    [ -n "$path" ] || { log "cannot find failing test $f"; gate_fail "a test failed: $f"; return 1; }
    # shellcheck disable=SC2086
    (cd "$REPO" && vp test run $path) >>"$STATE/fork-retest.out" 2>&1
  done <<<"$files"
  lines="$(comm -12 <(echo "$lines") <(failed_tests "$STATE/fork-retest.out"))"
  [ -n "$lines" ] || { log "every check:changed test failure passed when re-run alone (flaky)"; return 0; }
  if [ ! -d "$UPSTREAM_WT" ]; then
    git worktree add -q --detach "$UPSTREAM_WT" "$UP" || return 1
  fi
  git -C "$UPSTREAM_WT" checkout -q -f --detach "$UP" || return 1
  (cd "$UPSTREAM_WT" && vp i >/dev/null 2>&1) || return 1
  files="$(echo "$lines" | sed -E 's/ > .*//; s/ \[.*//' | sort -u)"
  : >"$STATE/upstream-test.out"
  while IFS= read -r f; do
    path="$(git -C "$UPSTREAM_WT" ls-files | grep -E "(^|/)${f//./\\.}$" | tr '\n' ' ')"
    [ -n "$path" ] || { log "failing test $f does not exist upstream"; gate_fail "a test failed: $f"; return 1; }
    # shellcheck disable=SC2086
    (cd "$UPSTREAM_WT" && vp test run $path) >>"$STATE/upstream-test.out" 2>&1
  done <<<"$files"
  up_lines="$(failed_tests "$STATE/upstream-test.out")"
  missing="$(comm -23 <(echo "$lines") <(echo "$up_lines"))"
  if [ -n "$missing" ]; then
    log "failures not reproduced on plain upstream:"; echo "$missing" | sed 's/^/  /'
    gate_fail "$(echo "$missing" | wc -l | tr -d ' ') test(s) failed that pass on plain upstream, e.g. $(echo "$missing" | head -1)"
    return 1
  fi
  log "every check:changed test failure also fails on plain upstream (pre-existing):"
  echo "$lines" | sed 's/^/  /'
}

resolver_prompt() {
  local group gate_cmds=""
  for group in "${FORK_TEST_GROUPS[@]+"${FORK_TEST_GROUPS[@]}"}"; do
    gate_cmds+="   - \`vp test run $(group_files "$group" | sed 's/ $//')\`"$'\n'
  done
  [ "$RUN_CHECK_CHANGED" = 1 ] && gate_cmds+="   - \`vp run check:changed $UP_REF\`"$'\n'
  cat <<EOF
You are running unattended inside $REPO. No human will read or answer questions until you exit.

A \`git rebase $UP_REF\` of the branch $FORK_BRANCH stopped on conflicts. The branch is a
personal fork of T3 Code ($UPSTREAM_URL) with the owner's own changes on top.

Your job:
1. Resolve every conflict, keeping BOTH upstream's intent and the fork's intent. Upstream's
   refactors win on structure; re-apply the fork's additions on top of the new upstream code.
   Never drop either side's behavior silently.
2. \`git add\` the resolved files and run \`git rebase --continue\` (GIT_EDITOR is already \`true\`).
   Repeat for every commit until the rebase is complete (no .git/rebase-merge directory).
3. Run \`vp i\`, then the same checks the update script runs after you exit:
${gate_cmds}   Fix what the rebase broke, amending the fork commit that introduced the code
   (\`git commit --amend\` only while that commit is the one being replayed) or with a follow-up
   \`fix: ...\` commit after the rebase. Only fix failures in code the fork or your resolution
   touched. After you exit, the script re-runs every check and compares each failing test against
   a pristine $UP_REF checkout, so a failure that upstream already has is fine: don't
   investigate it, don't edit upstream code to work around it, just mention it.

Hard rules:
- Never renumber, rename or edit database migration ids/names in
  apps/server/src/persistence/Migrations.ts or Migrations/. If a migration id conflict appears,
  stop and exit, explaining why.
- Never run git push, git reset, git rebase --abort, git rebase --skip, or anything outside this repo.
- Never touch ~/.t3, never start a dev server or the app.
- Run each command on its own (no \`cd\`, \`&&\`, pipes or subshells) so the permission rules match.
- Commit messages use \`<type>: <description>\`.
EOF
  if [ -f "$DIY_HOME/fork-notes.md" ]; then
    printf '\nNotes from the fork owner about what the fork changes:\n\n'
    cat "$DIY_HOME/fork-notes.md"
  fi
  printf '\nWhen you finish, print one line starting with RESULT: success, or RESULT: failed <reason>.\n'
}

resolver_label() {
  case "$RESOLVER_PROVIDER" in codex) printf 'Codex' ;; *) printf 'Claude Code' ;; esac
  [ -n "$RESOLVER_MODEL" ] && printf ' (%s)' "$RESOLVER_MODEL"
  return 0
}

# ---------------------------------------------------------------- no push while the agent runs
# The resolver must never push; the script pushes itself, after the tests. Codex has no per-command
# deny list, so this works for any provider: every remote's push URL points nowhere in .git/config
# for the agent's run. The originals are saved first and put back by restore_push_urls, which also
# runs from the EXIT trap and at the start of the next run (in case this one was SIGKILLed).
push_urls_saved_file() { echo "$STATE/push-urls.saved"; }
DEAD_PUSH_URL="/dev/null/t3code-diy-push-disabled"

# Saved as "name<TAB>url<TAB>pushurl" lines (pushurl empty when the remote has none).
disable_push_urls() {
  local saved r u p
  saved="$(push_urls_saved_file)"
  [ -f "$saved" ] && restore_push_urls
  : >"$saved.tmp"
  for r in $(git -C "$REPO" remote); do
    u="$(git -C "$REPO" config --get "remote.$r.url")"
    if p="$(git -C "$REPO" config --get-all "remote.$r.pushurl")"; then
      printf '%s\n' "$p" | while IFS= read -r one; do printf '%s\t%s\t%s\n' "$r" "$u" "$one"; done >>"$saved.tmp"
    else
      printf '%s\t%s\t\n' "$r" "$u" >>"$saved.tmp"
    fi
  done
  mv -f "$saved.tmp" "$saved"
  for r in $(git -C "$REPO" remote); do
    git -C "$REPO" config --replace-all "remote.$r.pushurl" "$DEAD_PUSH_URL" || return 1
  done
  log "push disabled for the resolver (push URLs of: $(git -C "$REPO" remote | tr '\n' ' '))"
}

# Puts every remote back as it was saved: its URL and push URLs. A remote the agent added goes.
restore_push_urls() {
  local saved r u p
  saved="$(push_urls_saved_file)"
  [ -f "$saved" ] || return 0
  for r in $(git -C "$REPO" remote); do
    if cut -f1 "$saved" | grep -qxF "$r"; then
      git -C "$REPO" config --unset-all "remote.$r.pushurl" 2>/dev/null
    else
      git -C "$REPO" remote remove "$r" && log "removed remote $r, added while the resolver ran"
    fi
  done
  while IFS="$(printf '\t')" read -r r u p; do
    [ -n "$r" ] || continue
    git -C "$REPO" remote get-url "$r" >/dev/null 2>&1 || git -C "$REPO" remote add "$r" "$u"
    [ "$(git -C "$REPO" config --get "remote.$r.url")" = "$u" ] || git -C "$REPO" config "remote.$r.url" "$u"
    [ -n "$p" ] && git -C "$REPO" config --add "remote.$r.pushurl" "$p"
  done <"$saved"
  rm -f "$saved"
  log "push URLs restored"
}

# The fork's branch on GitHub, so a push that got past the lockout is caught before anything else.
remote_branch_sha() {
  git -C "$REPO" ls-remote origin "refs/heads/$FORK_BRANCH" 2>/dev/null | awk '{print $1}'
}

run_resolver() {
  local prompt_file="$STATE/resolver-prompt.txt" out="$STATE/resolver-output.txt" problem before after
  resolver_prompt >"$prompt_file"
  problem="$(resolver_problem "$RESOLVER_PROVIDER")"
  if [ -n "$problem" ]; then
    log "not starting the conflict resolver: $problem"
    RUN_RESULT=conflict_unresolved
    restore_branch
    fail "the rebase conflicts and $problem"
  fi
  before="$(remote_branch_sha)"
  disable_push_urls || { restore_push_urls; fail "could not disable pushing for the resolver"; }
  log "starting $(resolver_label) to resolve conflicts (prompt: $prompt_file)"
  set -m
  (
    # Belt and braces next to the push URLs: no SSH, no credential prompts.
    export GIT_SSH_COMMAND=/usr/bin/false GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false GIT_TERMINAL_PROMPT=0
    "resolver_cmd_$RESOLVER_PROVIDER" "$prompt_file"
  ) >"$out" 2>&1 &
  RESOLVER_PID=$!
  set +m
  local waited=0 limit=$((RESOLVER_TIMEOUT_MIN * 60))
  while kill -0 "$RESOLVER_PID" 2>/dev/null; do
    sleep 15; waited=$((waited + 15))
    if [ "$waited" -ge "$limit" ]; then
      log "$(resolver_label) timed out after ${limit}s; stopping it"
      kill -- "-$RESOLVER_PID" 2>/dev/null
      sleep 5; kill -9 -- "-$RESOLVER_PID" 2>/dev/null
      break
    fi
  done
  wait "$RESOLVER_PID" 2>/dev/null
  local rc=$?
  RESOLVER_PID=""
  restore_push_urls
  log "$(resolver_label) exited ($rc). Output:"
  sed "s/^/  $RESOLVER_PROVIDER| /" "$out"
  after="$(remote_branch_sha)"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    restore_branch
    fail "origin/$FORK_BRANCH moved from $before to $after while the resolver ran; check your fork by hand"
  fi
}

# claude -p with an allowlist: edits, git add/commit/rebase --continue and the test commands only.
resolver_cmd_claude() {
  local model=()
  [ -n "$RESOLVER_MODEL" ] && model=(--model "$RESOLVER_MODEL")
  claude -p "$(cat "$1")" \
    "${model[@]+"${model[@]}"}" \
    --strict-mcp-config --no-session-persistence --setting-sources project \
    --permission-mode acceptEdits \
    --allowedTools "Read" "Edit" "Write" "Glob" "Grep" \
    "Bash(git status:*)" "Bash(git diff:*)" "Bash(git add:*)" "Bash(git rm:*)" "Bash(git log:*)" \
    "Bash(git show:*)" "Bash(git rebase --continue:*)" "Bash(git checkout --ours:*)" \
    "Bash(git checkout --theirs:*)" "Bash(git restore:*)" "Bash(git rerere:*)" \
    "Bash(git ls-files:*)" "Bash(git merge-base:*)" "Bash(git commit:*)" "Bash(git range-diff:*)" \
    "Bash(vp i:*)" "Bash(vp install:*)" "Bash(vp test run:*)" "Bash(vp run check:changed:*)" \
    "Bash(vp run typecheck:*)" "Bash(vp run fmt:*)" "Bash(vp fmt:*)" "Bash(vp lint:*)" \
    "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)" "Bash(rg:*)" "Bash(grep:*)" \
    --disallowedTools "Bash(git push:*)" "Bash(git reset:*)" "Bash(git rebase --abort:*)" \
    "Bash(git rebase --skip:*)" "Bash(git checkout -B:*)" "Bash(git config:*)" "Bash(git remote:*)" \
    "WebFetch" "WebSearch" \
    </dev/null
}

# codex exec has no per-command allowlist. It runs without its sandbox because the rebase writes to
# .git and vp i writes outside the repo, both of which workspace-write refuses; the push lockout
# above is what keeps it from pushing. The prompt comes in on stdin.
resolver_cmd_codex() {
  local model=()
  [ -n "$RESOLVER_MODEL" ] && model=(-m "$RESOLVER_MODEL")
  codex exec -C "$REPO" "${model[@]+"${model[@]}"}" \
    --sandbox danger-full-access --ephemeral --color never \
    -o "$STATE/resolver-last-message.txt" - <"$1"
}
