# t3code-diy status: what is installed, scheduled and built.
# shellcheck shell=bash

cmd_status() {
  case "${1:-}" in -h | --help) echo "Usage: t3code-diy status"; return 0 ;; esac
  load_config
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
  echo "feed:      $FEED_URL $(curl -fsS -o /dev/null "${FEED_URL}nightly-mac.yml" 2>/dev/null && echo '(answering)' || echo '(not answering)')"
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
    echo "running:   ${pids:+yes (pids $pids)}${pids:-no}"
  fi
  if [ -d "$REPO/.git" ]; then
    echo "repo:      $(git -C "$REPO" rev-parse --abbrev-ref HEAD) at $(git -C "$REPO" rev-parse --short=12 HEAD)$([ -d "$REPO/.git/rebase-merge" ] && echo ' (REBASE IN PROGRESS)')"
  fi
  log="$(ls -1t "$LOGS"/update-*.log 2>/dev/null | head -1)"
  if [ -n "$log" ]; then
    echo "last run:  $log"
    grep -E '^\[[0-9-]+ [0-9:]+\] ' "$log" | tail -5 | sed 's/^/  /'
  fi
}
