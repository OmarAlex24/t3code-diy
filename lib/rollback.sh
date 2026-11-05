# t3code-diy rollback: put the app and data from before the last switch back.
# shellcheck shell=bash

rollback_usage() {
  cat <<EOF
Usage: t3code-diy rollback [<backup-dir>] [--yes] [--no-open]   (replace mode only)

Restores the app and data saved by the last switch (or the backup you pass). Your current data
is moved aside, not deleted. Run it from Terminal.app, not from inside T3 Code.

This only works while the official app can still open the pre-switch database. See README,
"Migration collisions".
EOF
}

cmd_rollback() {
  local backup="" assume_yes=0 open_app=1 arg
  for arg in "$@"; do
    case "$arg" in
      --yes | -y) assume_yes=1 ;;
      --no-open) open_app=0 ;;
      -h | --help) rollback_usage; return 0 ;;
      -*) echo "unknown option: $arg" >&2; rollback_usage >&2; return 2 ;;
      *) backup="$arg" ;;
    esac
  done
  load_config
  is_side_by_side && die "rollback is for replace mode; in side-by-side mode use: t3code-diy uninstall-app (see README, Modes)"

  backup="${backup:-$(cat "$STATE/last-switch-backup" 2>/dev/null || true)}"
  [ -n "$backup" ] && [ -f "$backup/manifest" ] || die "no switch backup found (pass the backup dir)"
  local saved_app="$backup/$APP_NAME.app"
  cat "$backup/manifest"
  echo "Installed now: $(plist_version "$INSTALLED_APP" || echo none)"
  if [ -d "$saved_app" ]; then
    echo "Restoring app $(plist_version "$saved_app") and the data from $backup"
  else
    echo "The backup has no app (none was installed before the switch); only the data comes back."
  fi
  local answer=y
  [ "$assume_yes" = 0 ] && read -r -p "Continue? [y/N] " answer
  [ "$answer" = y ] || return 1

  if [ "$assume_yes" = 0 ]; then
    echo "Quit T3 Code now (Cmd+Q, and stop any other T3 server using $USERDATA_DIR)."
    read -r -p "Press Enter once it has quit... "
  fi
  wait_for_app_quit "$assume_yes"

  # The fork-era database may hold upstream migrations newer than the official release, which the
  # official app refuses, so the pre-switch data comes back and the fork-era data is kept here.
  local aside d name
  aside="$BACKUPS/$(date +%Y%m%d-%H%M%S)-fork-state"
  mkdir -p "$aside"
  [ -d "$USERDATA_DIR" ] && mv "$USERDATA_DIR" "$aside/userdata"
  if [ -d "$backup/userdata" ]; then
    mkdir -p "$(dirname "$USERDATA_DIR")"
    cp -c -R "$backup/userdata" "$USERDATA_DIR" || die "restoring userdata failed; your fork-era data is in $aside"
  fi
  for d in "${ELECTRON_DATA_DIRS[@]}"; do
    name="$(basename "$d")"
    if [ -d "$backup/$name" ]; then
      [ -d "$d" ] && mv "$d" "$aside/$name"
      cp -c -R "$backup/$name" "$d" || die "restoring $d failed"
    fi
  done

  if [ -d "$INSTALLED_APP" ]; then
    if is_fork_build "$INSTALLED_APP"; then
      rm -rf "$INSTALLED_APP" 2>/dev/null || sudo rm -rf "$INSTALLED_APP"
    else
      mv "$INSTALLED_APP" "$aside/" 2>/dev/null || sudo mv "$INSTALLED_APP" "$aside/"
    fi
  fi
  if [ -d "$saved_app" ]; then
    ditto "$saved_app" "$INSTALLED_APP" 2>/dev/null || sudo ditto "$saved_app" "$INSTALLED_APP" || die "copying the app back failed"
    register_app "$INSTALLED_APP"
  fi

  echo
  echo "Done: $(plist_version "$INSTALLED_APP" || echo "no app") is back with the pre-switch data."
  echo "The fork-era data is in $aside"
  [ "$open_app" = 1 ] && [ -d "$INSTALLED_APP" ] || return 0
  answer=y
  [ "$assume_yes" = 0 ] && read -r -p "Open it now? [Y/n] " answer
  [ "${answer:-y}" = n ] || open "$INSTALLED_APP"
}
