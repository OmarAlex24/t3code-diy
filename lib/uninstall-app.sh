# t3code-diy uninstall-app: remove the side-by-side app. Its data stays unless you delete it.
# shellcheck shell=bash

uninstall_app_usage() {
  cat <<EOF
Usage: t3code-diy uninstall-app   (side-by-side mode only)

Removes $APPS_DIR/<SIDE_APP_NAME>.app. Refuses while it is running. The official T3 Code app
and the custom app's data are left alone (the paths are printed so you can delete them).
EOF
}

cmd_uninstall_app() {
  case "${1:-}" in
    -h | --help) uninstall_app_usage; return 0 ;;
    "") ;;
    *) echo "unknown option: $1" >&2; uninstall_app_usage >&2; return 2 ;;
  esac
  load_config
  is_side_by_side || die "uninstall-app is for side-by-side mode; in replace mode use: t3code-diy rollback"
  if [ ! -e "$INSTALLED_APP" ]; then
    echo "Nothing installed at $INSTALLED_APP."
    return 0
  fi
  is_fork_build "$INSTALLED_APP" || die "$INSTALLED_APP is not your side-by-side build; not touching it"
  local pids
  pids="$(installed_app_pids)"
  [ -z "$pids" ] || die "$INSTALLED_NAME is running (pids: $(echo "$pids" | tr '\n' ' ')). Quit it and run this again"

  [ "$APPS_DIR" = "/Applications" ] && "$LSREGISTER" -u "$INSTALLED_APP" 2>/dev/null
  rm -rf "$INSTALLED_APP" || die "could not remove $INSTALLED_APP"
  cat <<EOF
Removed $INSTALLED_APP. Its data is still here; delete it by hand if you don't want it:
  $SIDE_T3_HOME
  $HOME/Library/Application Support/$SIDE_USER_DATA_NAME
EOF
}
