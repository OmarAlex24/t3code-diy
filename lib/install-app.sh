# t3code-diy install-app: copy your newest build to /Applications as its own app (side-by-side).
# shellcheck shell=bash

install_app_usage() {
  cat <<EOF
Usage: t3code-diy install-app [<version>] [--open]   (side-by-side mode only)

Copies a build (newest by default) to $APPS_DIR/<SIDE_APP_NAME>.app. The official T3 Code app
is not touched. Refuses while the custom app is running; after the first install it updates
itself from the local feed, so you only need this again after changing a SIDE_* setting.

  --open  open the app when done
EOF
}

cmd_install_app() {
  local version="" open_app=0 arg
  for arg in "$@"; do
    case "$arg" in
      --open) open_app=1 ;;
      -h | --help) install_app_usage; return 0 ;;
      -*) echo "unknown option: $arg" >&2; install_app_usage >&2; return 2 ;;
      *) version="$arg" ;;
    esac
  done
  load_config
  is_side_by_side || die "install-app is for side-by-side mode; in replace mode use: t3code-diy switch"

  version="${version:-$(latest_build)}"
  [ -n "$version" ] || die "no build in $BUILDS yet. Run: t3code-diy update"
  local app="$BUILDS/$version/$INSTALLED_NAME.app" installed=""
  [ -d "$app" ] || die "no '$INSTALLED_NAME.app' in $BUILDS/$version (a replace-mode build?). Run: t3code-diy update --force"
  codesign --verify --deep --strict "$app" || die "the build's signature does not verify"
  is_fork_build "$app" || die "the build is not signed as $APP_BUNDLE_ID with your local identity"

  if [ -e "$INSTALLED_APP" ]; then
    is_fork_build "$INSTALLED_APP" || die "$INSTALLED_APP exists and is not your side-by-side build; move it away first"
    installed="$(plist_version "$INSTALLED_APP")"
    if [ "$installed" = "$version" ]; then
      echo "$INSTALLED_APP already is $version."
      [ "$open_app" = 1 ] && open "$INSTALLED_APP"
      return 0
    fi
    version_gt "$installed" "$version" && die "the installed app ($installed) is newer than $version"
  fi
  local pids
  pids="$(installed_app_pids)"
  [ -z "$pids" ] || die "$INSTALLED_NAME is running (pids: $(echo "$pids" | tr '\n' ' ')). Quit it and run this again"

  curl -fsS -o /dev/null "${FEED_URL}nightly-mac.yml" 2>/dev/null \
    || echo "warning: the local feed ($FEED_URL) is not answering; the app won't see updates until it does."

  echo "Installing $version into $INSTALLED_APP${installed:+ (replacing $installed)}"
  mkdir -p "$APPS_DIR"
  local tmp="$APPS_DIR/.$INSTALLED_NAME.app.t3code-diy"
  rm -rf "$tmp"
  ditto "$app" "$tmp" || { rm -rf "$tmp"; die "copy failed"; }
  rm -rf "$INSTALLED_APP" || die "could not remove the old $INSTALLED_APP"
  mv "$tmp" "$INSTALLED_APP" || die "could not move the new app to $INSTALLED_APP"
  register_app "$INSTALLED_APP"

  cat <<EOF

Done. $INSTALLED_APP ($version) runs next to the official app.
- Its data: $SIDE_T3_HOME and ~/Library/Application Support/$SIDE_USER_DATA_NAME
- Its server: port $SIDE_PORT. Updates come from $FEED_URL through the app's own update button.
- First launch: macOS asks to let it use "t3code Safe Storage" in your keychain. Enter your
  password and choose "Always Allow". Updates keep the same signature, so it won't ask again.
- Remove it: t3code-diy uninstall-app
EOF
  [ "$open_app" = 1 ] && open "$INSTALLED_APP"
  return 0
}
