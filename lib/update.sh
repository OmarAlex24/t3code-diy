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
  CLAUDE_PID=""
  PATCHED=0
  trap update_cleanup EXIT

  export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_TERMINAL_PROMPT=0
  cd "$REPO" || fail "repo missing: $REPO"

  log "== t3code-diy update start (mode=$MODE force=$FORCE no_push=$NO_PUSH reuse_dist=$REUSE_DIST)"
  log "fork: $FORK_URL ($FORK_BRANCH)  upstream: $UPSTREAM_URL ($UPSTREAM_BRANCH)"
  log "tools: node $(node -v 2>&1) ($(type -P node)), $(vp --version 2>&1 | head -1), $(cargo --version 2>&1), claude $(claude --version 2>&1 | head -1)"

  # ------------------------------------------------------------ git: fetch & rebase
  rebase_in_progress && fail "a rebase is already in progress in $REPO; resolve or abort it by hand"
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
      fail "migration collision: upstream migration ids now reach $up_max and collide with your fork's migration $id $name. Renumbering is unsafe; decide by hand (see README, Caveats)"
    fi
  done < <(comm -13 <(migration_entries "$MB" | sort) <(migration_entries "$ORIG" | sort))

  RR_BEFORE="$(ls -1 .git/rr-cache 2>/dev/null | sort)"
  REBASED=0
  if git merge-base --is-ancestor "$UP" "$ORIG"; then
    log "branch already contains $UP_REF; no rebase needed"
  else
    log "rebasing $(git rev-list --count "$MB..$ORIG") fork commits onto $UP_REF ($(git rev-list --count "$MB..$UP") new upstream commits)"
    REBASED=1
    git rebase "$UP_REF"
    local used_claude=0 unresolved
    while rebase_in_progress; do
      unresolved="$(git diff --name-only --diff-filter=U)"
      if [ -z "$unresolved" ] && [ "$used_claude" = 0 ]; then
        log "conflicts resolved by rerere; continuing"
        git add -u && git rebase --continue && continue
      fi
      [ "$used_claude" = 1 ] && break
      log "conflicts in: $(echo "$unresolved" | tr '\n' ' ')"
      used_claude=1
      run_claude_resolver
    done
    if rebase_in_progress; then restore_branch; fail "rebase conflicts could not be resolved; the installed version is unchanged"; fi
    git merge-base --is-ancestor "$UP" HEAD || { restore_branch; fail "rebase result does not contain $UP_REF"; }
    [ -z "$(git status --porcelain --untracked-files=no)" ] || { restore_branch; fail "rebase left uncommitted changes"; }
    local dup
    dup="$(migration_entries HEAD | awk '{print $1}' | sort | uniq -d)"
    [ -z "$dup" ] || { restore_branch; fail "duplicate migration ids after rebase: $dup"; }
  fi
  HEAD_SHA="$(git rev-parse HEAD)"
  log "result HEAD=$HEAD_SHA ($(git rev-list --count "$UP..HEAD") commits on top of upstream)"

  if [ "$HEAD_SHA" = "$(cat "$STATE/last-built-sha" 2>/dev/null)" ] && [ "$FORCE" = 0 ]; then
    log "nothing changed since the last build ($HEAD_SHA); done"
    exit 0
  fi

  # ------------------------------------------------------------ tests
  if ! run_gate; then
    if [ "$REBASED" = 1 ]; then
      log "tests failed after rebase; restoring $FORK_BRANCH to $ORIG"
      restore_branch
      vp i >/dev/null 2>&1
    fi
    fail "tests failed; the installed version is unchanged"
  fi
  log "tests green"

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

  # ------------------------------------------------------------ prune
  local old
  ls -1 "$BUILDS" | grep -E '^[0-9]' | sort -V | all_but_last "$KEEP_BUILDS" | while read -r old; do
    log "pruning build $old"; rm -rf "${BUILDS:?}/$old"
  done
  ls -1 "$FEED"/T3-Code-*-arm64.zip 2>/dev/null | sort -V | all_but_last "$KEEP_BUILDS" | while read -r old; do
    log "pruning feed $(basename "$old")"; rm -f "$old"
  done

  log "== done: $version"
  if [ -d "$INSTALLED_APP" ]; then
    notify "build ready" "$version is in the local feed. Use Check for updates in $INSTALLED_NAME." && log "notification sent"
  else
    notify "build ready" "$version is ready. Install it with: t3code-diy $(is_side_by_side && echo install-app || echo switch)" && log "notification sent"
  fi
  exit 0
}

update_cleanup() {
  [ -n "${CLAUDE_PID:-}" ] && kill -- "-$CLAUDE_PID" 2>/dev/null
  revert_side_patch
  rm -f "$LOCK"
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
    || fail "the side-by-side patch no longer applies to $SIDE_PATCH_FILE (upstream changed it). Nothing was built; the installed version is unchanged. Update $(side_patch)"
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

fail() {
  log "FAILED: $*"
  notify "update failed" "$* (log: $LOG)" && log "notification sent"
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

run_gate() {
  log "vp i"
  vp i || return 1
  local group files
  for group in "${FORK_TEST_GROUPS[@]+"${FORK_TEST_GROUPS[@]}"}"; do
    files="$(group_files "$group")"
    [ -n "$files" ] || { log "test group '$group' matches no files"; return 1; }
    log "fork tests ($group): $files"
    # shellcheck disable=SC2086
    vp test run $files || return 1
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
  if [ -n "$bad" ]; then log "check:changed failed: $bad"; return 1; fi
  failures_are_preexisting "$out"
}

# "file > suite > test" for every failed test in vitest output. Vitest prints the project as
# "|name|" without colors and as a colored badge with them (launchd runs get colors), so both
# forms are accepted once the escape codes are gone.
failed_tests() {
  sed $'s/\x1b\\[[0-9;]*m//g' "$1" \
    | sed -nE 's/^ FAIL +(\|[^|]*\| +|[^ ]+ +)?([^ ]+\.(test|spec)\.[cm]?[jt]sx?( > .*)?)$/\2/p' \
    | sort -u
}

# Re-runs the failing test files on a pristine upstream checkout; succeeds only when every
# failure reported for the fork also fails there (pre-existing upstream failures).
failures_are_preexisting() {
  local out="$1" lines files f path up_lines missing
  lines="$(failed_tests "$out")"
  [ -n "$lines" ] || { log "check:changed failed without test failures I can parse"; return 1; }
  if [ ! -d "$UPSTREAM_WT" ]; then
    git worktree add -q --detach "$UPSTREAM_WT" "$UP" || return 1
  fi
  git -C "$UPSTREAM_WT" checkout -q -f --detach "$UP" || return 1
  (cd "$UPSTREAM_WT" && vp i >/dev/null 2>&1) || return 1
  files="$(echo "$lines" | sed -E 's/ > .*//; s/ \[.*//' | sort -u)"
  : >"$STATE/upstream-test.out"
  while IFS= read -r f; do
    path="$(git -C "$UPSTREAM_WT" ls-files | grep -E "(^|/)${f//./\\.}$" | tr '\n' ' ')"
    [ -n "$path" ] || { log "failing test $f does not exist upstream"; return 1; }
    # shellcheck disable=SC2086
    (cd "$UPSTREAM_WT" && vp test run $path) >>"$STATE/upstream-test.out" 2>&1
  done <<<"$files"
  up_lines="$(failed_tests "$STATE/upstream-test.out")"
  missing="$(comm -23 <(echo "$lines") <(echo "$up_lines"))"
  if [ -n "$missing" ]; then
    log "failures not reproduced on plain upstream:"; echo "$missing" | sed 's/^/  /'
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

run_claude_resolver() {
  local prompt_file="$STATE/claude-prompt.txt" out="$STATE/claude-output.txt"
  resolver_prompt >"$prompt_file"
  log "starting Claude Code ($CLAUDE_MODEL) to resolve conflicts (prompt: $prompt_file)"
  # Any push the agent might attempt goes to a dead URL. The script pushes itself, after the tests.
  set -m
  GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=/dev/null/push-disabled \
    GIT_CONFIG_KEY_1=remote.upstream.pushurl GIT_CONFIG_VALUE_1=/dev/null/push-disabled \
    claude -p "$(cat "$prompt_file")" \
    --model "$CLAUDE_MODEL" \
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
    "Bash(git rebase --skip:*)" "Bash(git checkout -B:*)" "WebFetch" "WebSearch" \
    </dev/null >"$out" 2>&1 &
  CLAUDE_PID=$!
  set +m
  local waited=0 limit=$((CLAUDE_TIMEOUT_MIN * 60))
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep 15; waited=$((waited + 15))
    if [ "$waited" -ge "$limit" ]; then
      log "Claude Code timed out after ${limit}s; stopping it"
      kill -- "-$CLAUDE_PID" 2>/dev/null
      sleep 5; kill -9 -- "-$CLAUDE_PID" 2>/dev/null
      break
    fi
  done
  wait "$CLAUDE_PID" 2>/dev/null
  local rc=$?
  CLAUDE_PID=""
  log "Claude Code exited ($rc). Output:"
  sed 's/^/  claude| /' "$out"
}
