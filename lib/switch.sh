# t3code-diy switch: replace the installed T3 Code app with your newest fork build.
# shellcheck shell=bash

switch_usage() {
  cat <<EOF
Usage: t3code-diy switch [<version>] [--yes] [--no-open]   (replace mode only)

Run it from Terminal.app, not from a terminal inside T3 Code: it asks you to quit T3 Code.
Backs up your T3 Code data and the current app, then installs the build (newest by default).

  --yes      don't ask (fails instead of waiting if T3 Code is still running)
  --no-open  don't open the app at the end
EOF
}

cmd_switch() {
  local version="" assume_yes=0 open_app=1 arg
  for arg in "$@"; do
    case "$arg" in
      --yes | -y) assume_yes=1 ;;
      --no-open) open_app=0 ;;
      -h | --help) switch_usage; return 0 ;;
      -*) echo "unknown option: $arg" >&2; switch_usage >&2; return 2 ;;
      *) version="$arg" ;;
    esac
  done
  load_config
  is_side_by_side && die "switch is for replace mode; in side-by-side mode use: t3code-diy install-app (see README, Modes)"

  version="${version:-$(latest_build)}"
  [ -n "$version" ] || die "no build in $BUILDS yet. Run: t3code-diy update"
  local build="$BUILDS/$version" app installed
  app="$build/$APP_NAME.app"
  [ -d "$app" ] || die "build not found: $app"

  installed="$(plist_version "$INSTALLED_APP" || true)"
  echo "Fork build:    $version"
  echo "Installed now: ${installed:-none} ($INSTALLED_APP)"

  # --- checks before touching anything
  codesign --verify --deep --strict "$app" || die "the build's signature does not verify"
  is_fork_build "$app" || die "the build is not signed with your local identity"
  if is_fork_build "$INSTALLED_APP"; then
    echo "$INSTALLED_APP already is a fork build; it updates itself from the app. Nothing to switch."
    return 0
  fi
  if [ -n "$installed" ] && ! version_gt "$version" "$installed"; then
    die "the installed app ($installed) is not older than the build ($version). Run t3code-diy update first."
  fi

  # Every migration your database recorded must exist, with the same name, in the fork build.
  # Otherwise the app you run is newer than the upstream code this build was rebased on.
  local db="$USERDATA_DIR/statev2.sqlite" commit missing
  commit="$(cat "$build/commit")"
  if [ -f "$db" ]; then
    missing="$(comm -23 \
      <(sqlite3 "file:$db?mode=ro&immutable=1" "SELECT migration_id || ' ' || name FROM effect_sql_migrations" | sort) \
      <(migration_entries "$commit" | sort))"
    if [ -n "$missing" ]; then
      echo "Your database has migrations this fork build does not know:"; echo "$missing"
      die "wait for the next update to rebase onto a newer upstream, then retry"
    fi
    echo "Database check: every recorded migration is known to the fork build."
  fi

  curl -fsS -o /dev/null "${FEED_URL}nightly-mac.yml" 2>/dev/null \
    || echo "warning: the local feed ($FEED_URL) is not answering; the app won't see updates until it does."
  local policy="/Library/Application Support/T3Code/policy.json"
  [ -f "$policy" ] && echo "warning: $policy exists; an updates.feedUrl in it overrides the local feed."

  echo
  if [ "$assume_yes" = 0 ]; then
    echo "Quit T3 Code now (Cmd+Q, and stop any other T3 server using $USERDATA_DIR)."
    read -r -p "Press Enter once it has quit... "
  fi
  wait_for_app_quit "$assume_yes"

  # --- backup (the app is moved, not copied, so the backup is exactly what ran)
  local backup d
  backup="$BACKUPS/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  echo "Backing up to $backup"
  [ -d "$USERDATA_DIR" ] && { cp -c -R "$USERDATA_DIR" "$backup/userdata" || die "userdata backup failed"; }
  for d in "${ELECTRON_DATA_DIRS[@]}"; do
    if [ -d "$d" ]; then cp -c -R "$d" "$backup/$(basename "$d")" || die "backup of $d failed"; fi
  done
  if [ -d "$INSTALLED_APP" ]; then
    mv "$INSTALLED_APP" "$backup/" 2>/dev/null || sudo mv "$INSTALLED_APP" "$backup/" || die "could not move $INSTALLED_APP"
  fi
  cat >"$backup/manifest" <<EOF
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
replaced_version=${installed:-none}
installed_fork_version=$version
app=$INSTALLED_APP
userdata=$USERDATA_DIR
EOF

  # --- install
  echo "Installing $version into $APPS_DIR"
  mkdir -p "$APPS_DIR"
  ditto "$app" "$INSTALLED_APP" 2>/dev/null || sudo ditto "$app" "$INSTALLED_APP" || die "copy failed; your old app is in $backup"
  register_app "$INSTALLED_APP"
  echo "$backup" >"$STATE/last-switch-backup"

  cat <<EOF

Done. $INSTALLED_APP is now your fork ($version).
- First launch: macOS asks to let it use "t3code Safe Storage" in your keychain. Enter your
  password and choose "Always Allow". Updates keep the same signature, so it won't ask again.
- Updates come from $FEED_URL through the app's own update button.
- Back to the official app: t3code-diy rollback
EOF
  [ "$open_app" = 1 ] || return 0
  local answer=y
  [ "$assume_yes" = 0 ] && read -r -p "Open it now? [Y/n] " answer
  [ "${answer:-y}" = n ] || open "$INSTALLED_APP"
}
