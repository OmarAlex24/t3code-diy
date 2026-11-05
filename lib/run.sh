# t3code-diy run: start the update job in launchd now and return right away.
# shellcheck shell=bash

cmd_run() {
  case "${1:-}" in
    -h | --help)
      echo "Usage: t3code-diy run"
      echo "Starts the daily update job now through launchd and returns; 'status' shows its progress."
      return 0 ;;
    "") ;;
    *) echo "unknown option: $1" >&2; return 2 ;;
  esac
  load_config
  # shellcheck source=status.sh
  source "$KIT_SRC/lib/status.sh"
  if update_in_progress; then
    echo "an update is already running"
    return 0
  fi
  [ -n "$(update_job_state)" ] || die "the update job $UPDATE_LABEL is not loaded; run: t3code-diy install"
  launchctl kickstart "gui/$(id -u)/$UPDATE_LABEL" >/dev/null || die "launchctl kickstart $UPDATE_LABEL failed"
  echo "started $UPDATE_LABEL"
}
