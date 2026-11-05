# t3code-diy log: the last run's log, without terminal colors.
# shellcheck shell=bash

cmd_log() {
  local tail=200
  while [ $# -gt 0 ]; do
    case "$1" in
      --tail) tail="${2:-}"; shift ;;
      -h | --help) echo "Usage: t3code-diy log [--tail N]   (default 200 lines, at most 5000)"; return 0 ;;
      *) echo "unknown option: $1" >&2; return 2 ;;
    esac
    shift
  done
  [[ "$tail" =~ ^[0-9]+$ ]] && [ "$tail" -ge 1 ] && [ "$tail" -le 5000 ] || die "--tail must be 1-5000"
  load_config
  # shellcheck source=status.sh
  source "$KIT_SRC/lib/status.sh"
  load_last_run
  local log="$LR_LOG"
  [ -n "$log" ] || log="$(ls -1t "$LOGS"/update-*.log 2>/dev/null | head -1)"
  [ -n "$log" ] && [ -f "$log" ] || die "no update log yet in $LOGS"
  tail -n "$tail" "$log" | sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'
}
