# t3code-diy uninstall: unload the launchd jobs, optionally delete everything.
# shellcheck shell=bash

uninstall_usage() {
  cat <<EOF
Usage: t3code-diy uninstall [--purge] [--yes]

Unloads and removes the two launchd jobs. Your installed app is left alone.

  --purge  also delete $DIY_HOME (repo, builds, feed, backups, signing identity).
           A fork build you already installed keeps working but gets no more updates, and a
           new identity means macOS asks for keychain access again.
EOF
}

cmd_uninstall() {
  local purge=0 assume_yes=0 arg
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      --yes | -y) assume_yes=1 ;;
      -h | --help) uninstall_usage; return 0 ;;
      *) echo "unknown option: $arg" >&2; uninstall_usage >&2; return 2 ;;
    esac
  done
  load_config
  local uid label
  uid="$(id -u)"

  local lock="$STATE/update.lock" pid
  if pid="$(cat "$lock" 2>/dev/null)" && kill -0 "$pid" 2>/dev/null; then
    die "an update is running (pid $pid); wait for it or stop it first"
  fi

  if [ "$purge" = 1 ] && [ "$assume_yes" = 0 ]; then
    if [ -d "$BACKUPS" ] && [ -n "$(ls -A "$BACKUPS" 2>/dev/null)" ]; then
      echo "warning: $BACKUPS has switch backups (your pre-switch app and data)."
    fi
    local answer
    read -r -p "Delete $DIY_HOME entirely? [y/N] " answer
    [ "$answer" = y ] || return 1
  fi

  for label in "$FEED_LABEL" "$UPDATE_LABEL"; do
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      launchctl bootout "gui/$uid/$label" && echo "unloaded $label"
    fi
    if [ -f "$AGENTS_DIR/$label.plist" ]; then
      rm -f "$AGENTS_DIR/$label.plist" && echo "removed $AGENTS_DIR/$label.plist"
    fi
  done

  if [ "$purge" = 1 ]; then
    if [ -d "$REPO/.git" ] && [ -d "$UPSTREAM_WT" ]; then
      git -C "$REPO" worktree remove --force "$UPSTREAM_WT" 2>/dev/null
    fi
    # The keychain never joins the search list, but drop it from there in case someone added it.
    if security list-keychains -d user | grep -qF "$KEYCHAIN"; then
      security delete-keychain "$KEYCHAIN"
    fi
    rm -rf "${DIY_HOME:?}"
    echo "deleted $DIY_HOME"
  else
    echo "kept $DIY_HOME (run with --purge to delete it)"
  fi
}
