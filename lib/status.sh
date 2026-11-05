# t3code-diy status: what is installed, scheduled and built. --json for scripts and the app.
# shellcheck shell=bash

status_usage() {
  cat <<EOF2
Usage: t3code-diy status [--json]

  --json   one JSON object on stdout (the format is in the README, "Machine-readable status")
EOF2
}

cmd_status() {
  local json=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -h | --help) status_usage; return 0 ;;
      *) echo "unknown option: $arg" >&2; status_usage >&2; return 2 ;;
    esac
  done
  load_config
  if [ "$json" = 1 ]; then status_json; return; fi
  local uid installed last log label state
  uid="$(id -u)"
  echo "home:      $DIY_HOME"
  echo "fork:      $FORK_URL ($FORK_BRANCH)"
  echo "upstream:  $UPSTREAM_URL ($UPSTREAM_BRANCH)"
  if is_side_by_side; then
    echo "mode:      side-by-side: \"$SIDE_APP_NAME\" ($SIDE_BUNDLE_ID), home $SIDE_T3_HOME, profile $SIDE_USER_DATA_NAME, port $SIDE_PORT"
  else
    echo "mode:      replace"
  fi
  echo "resolver:  $RESOLVER_PROVIDER${RESOLVER_MODEL:+ ($RESOLVER_MODEL)}"
  echo "feed:      $FEED_URL $(curl -fsS --max-time 2 -o /dev/null "${FEED_URL}nightly-mac.yml" 2>/dev/null && echo '(answering)' || echo '(not answering)')"
  printf 'jobs:      '
  for label in "$FEED_LABEL" "$UPDATE_LABEL"; do
    if state="$(launchctl print "gui/$uid/$label" 2>/dev/null)"; then
      printf '%s [%s, last exit %s]  ' "$label" \
        "$(echo "$state" | sed -n 's/^[[:space:]]*state = //p' | head -1)" \
        "$(echo "$state" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
    else
      printf '%s [not loaded]  ' "$label"
    fi
  done
  echo
  echo "schedule:  daily $SCHEDULE_HOUR:$(printf %02d "$SCHEDULE_MINUTE")$([ "$RUN_AT_LOGIN" = 1 ] && echo ' and at login')"
  last="$(cat "$STATE/last-version" 2>/dev/null)"
  echo "last build: ${last:-none}$([ -f "$STATE/last-built-sha" ] && echo " ($(cut -c1-12 "$STATE/last-built-sha"))")"
  echo "builds:    $(ls -1 "$BUILDS" 2>/dev/null | grep -E '^[0-9]' | sort -V | tr '\n' ' ')"
  installed="$(plist_version "$INSTALLED_APP")"
  if [ -z "$installed" ]; then
    echo "installed: none at $INSTALLED_APP (run t3code-diy $(is_side_by_side && echo install-app || echo switch))"
  elif is_fork_build "$INSTALLED_APP"; then
    echo "installed: $installed (your fork build)"
  else
    echo "installed: $installed (not a fork build; run t3code-diy switch)"
  fi
  if [ -n "$installed" ] && is_side_by_side; then
    local pids
    pids="$(installed_app_pids | tr '\n' ' ')"
    if [ -n "$pids" ]; then echo "running:   yes (pids $pids)"; else echo "running:   no"; fi
  fi
  if [ -d "$REPO/.git" ]; then
    echo "repo:      $(git -C "$REPO" rev-parse --abbrev-ref HEAD) at $(git -C "$REPO" rev-parse --short=12 HEAD)$([ -d "$REPO/.git/rebase-merge" ] && echo ' (REBASE IN PROGRESS)')"
  fi
  load_last_run
  if [ -n "$LR_RESULT" ]; then
    echo "last run:  $LR_RESULT${LR_REASON:+: $LR_REASON} (${LR_STARTED:-?} to ${LR_ENDED:-now})"
    echo "  log:     $LR_LOG"
  fi
  log="${LR_LOG:-$(ls -1t "$LOGS"/update-*.log 2>/dev/null | head -1)}"
  if [ -n "$log" ] && [ -f "$log" ]; then
    grep -E '^\[[0-9-]+ [0-9:]+\] ' "$log" | tail -5 | sed 's/^/  /'
  fi
}

# The update job's launchd state ("running", "not running", ...), empty when it isn't loaded.
update_job_state() {
  launchctl print "gui/$(id -u)/$UPDATE_LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1
}

update_in_progress() { update_running || [ "$(update_job_state)" = running ]; }

# Sets LR_* from state/last-run, or, before the kit wrote one, from the newest log.
load_last_run() {
  LR_STARTED="" LR_ENDED="" LR_RESULT="" LR_REASON="" LR_VERSION="" LR_LOG="" LR_PID=""
  local rec="$STATE/last-run"
  if [ -f "$rec" ]; then
    lr() { sed -n "s/^$1=//p" "$rec" | head -1; }
    LR_STARTED="$(lr started_at)"; LR_ENDED="$(lr ended_at)"; LR_RESULT="$(lr result)"
    LR_REASON="$(lr reason)"; LR_VERSION="$(lr version)"; LR_LOG="$(lr log)"; LR_PID="$(lr pid)"
    if [ "$LR_RESULT" = running ] && ! { [ -n "$LR_PID" ] && kill -0 "$LR_PID" 2>/dev/null; }; then
      LR_RESULT=interrupted
      LR_REASON="the run stopped without finishing (killed, or the Mac slept or shut down)"
    fi
    return 0
  fi
  local log line name
  log="$(ls -1t "$LOGS"/update-*.log 2>/dev/null | head -1)"
  [ -n "$log" ] || return 0
  LR_LOG="$log"
  name="$(basename "$log" .log)"; name="${name#update-}"
  LR_STARTED="$(iso_from_local "$name")"
  line="$(grep -E '^\[[0-9-]+ [0-9:]+\] ' "$log" | tail -1)"
  LR_ENDED="$(iso_from_local "$(echo "$line" | sed -E 's/^\[([^]]+)\].*/\1/')")"
  if line="$(grep -E '^\[[0-9-]+ [0-9:]+\] == done: ' "$log" | tail -1)" && [ -n "$line" ]; then
    LR_RESULT=ok; LR_VERSION="${line##*== done: }"; LR_REASON="built $LR_VERSION"
  elif grep -qE '^\[[0-9-]+ [0-9:]+\] nothing changed since the last build' "$log"; then
    LR_RESULT=up_to_date; LR_REASON="nothing changed since the last build"
  elif line="$(grep -E '^\[[0-9-]+ [0-9:]+\] FAILED' "$log" | tail -1)" && [ -n "$line" ]; then
    LR_REASON="$(echo "$line" | sed -E 's/^\[[^]]+\] FAILED( \([a-z_]+\))?: //; s/;? ?the installed version is unchanged\.?//')"
    case "$LR_REASON" in
      *"rebase conflicts"*) LR_RESULT=conflict_unresolved ;;
      *"tests failed"*) LR_RESULT=tests_failed ;;
      *migration*) LR_RESULT=migration_collision ;;
      *"push to origin failed"*) LR_RESULT=push_failed ;;
      *"build failed"* | *"signing failed"* | *"zip failed"*) LR_RESULT=build_failed ;;
      *) LR_RESULT=error ;;
    esac
  elif update_running; then
    LR_RESULT=running; LR_ENDED=""
  else
    LR_RESULT=interrupted; LR_REASON="the run stopped without finishing"
  fi
}

# The next StartCalendarInterval fire, when the job is loaded. At-login runs aren't predictable.
next_scheduled_run() {
  [ -n "$(update_job_state)" ] || return 0
  local now at
  now="$(date +%s)"
  at="$(date -j -v"${SCHEDULE_HOUR}"H -v"${SCHEDULE_MINUTE}"M -v0S +%s)"
  [ "$at" -gt "$now" ] || at="$(date -j -v+1d -v"${SCHEDULE_HOUR}"H -v"${SCHEDULE_MINUTE}"M -v0S +%s)"
  iso_from_epoch "$at"
}

status_json() {
  local installed running=0 loaded=0 fork_build=0 job
  installed="$(plist_version "$INSTALLED_APP")"
  [ -n "$installed" ] && is_fork_build "$INSTALLED_APP" 2>/dev/null && fork_build=1
  job="$(update_job_state)"
  [ -n "$job" ] && loaded=1
  { update_running || [ "$job" = running ]; } && running=1
  load_last_run
  # A kickstarted job shows as running before it writes its record.
  if [ "$running" = 1 ] && [ "$LR_RESULT" != running ]; then
    LR_RESULT=running LR_REASON="" LR_ENDED="" LR_VERSION="" LR_STARTED="$(iso_now)"
    LR_LOG="$(ls -1t "$LOGS"/update-*.log 2>/dev/null | head -1)"
  fi
  printf '{"schema":1'
  printf ',"kit":{"bin":%s,"home":%s}' "$(json_str "$KIT_SRC/bin/t3code-diy")" "$(json_str "$DIY_HOME")"
  printf ',"mode":%s' "$(json_str "$MODE")"
  printf ',"app":{"name":%s,"path":%s,"installedVersion":%s,"forkBuild":%s,"latestBuild":%s}' \
    "$(json_str "$INSTALLED_NAME")" "$(json_str "$INSTALLED_APP")" "$(json_str "$installed" null)" \
    "$(json_bool "$fork_build")" "$(json_str "$(cat "$STATE/last-version" 2>/dev/null)" null)"
  printf ',"fork":{"url":%s,"branch":%s}' "$(json_str "$FORK_URL")" "$(json_str "$FORK_BRANCH")"
  printf ',"upstream":{"url":%s,"branch":%s}' "$(json_str "$UPSTREAM_URL")" "$(json_str "$UPSTREAM_BRANCH")"
  printf ',"resolver":{"provider":%s,"model":%s,"timeoutMinutes":%s}' \
    "$(json_str "$RESOLVER_PROVIDER")" "$(json_str "$RESOLVER_MODEL")" "$((RESOLVER_TIMEOUT_MIN + 0))"
  printf ',"schedule":{"loaded":%s,"hour":%s,"minute":%s,"atLogin":%s,"nextRun":%s}' \
    "$(json_bool "$loaded")" "$((SCHEDULE_HOUR + 0))" "$((SCHEDULE_MINUTE + 0))" \
    "$(json_bool "$RUN_AT_LOGIN")" "$(json_str "$(next_scheduled_run)" null)"
  printf ',"running":%s' "$(json_bool "$running")"
  if [ -n "$LR_RESULT" ]; then
    printf ',"lastRun":{"result":%s,"reason":%s,"startedAt":%s,"endedAt":%s,"version":%s,"log":%s}' \
      "$(json_str "$LR_RESULT")" "$(json_str "$LR_REASON")" "$(json_str "$LR_STARTED" null)" \
      "$(json_str "$LR_ENDED" null)" "$(json_str "$LR_VERSION" null)" "$(json_str "$LR_LOG" null)"
  else
    printf ',"lastRun":null'
  fi
  printf '}\n'
}
