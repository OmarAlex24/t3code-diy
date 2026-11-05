# t3code-diy config: read or change single settings without re-running install.
# shellcheck shell=bash

# Settings `config set` may change, each with its own check. The rest are install's business
# (re-run install for schedule, port, labels and the SIDE_* values; they need launchd or a rebuild).
CONFIG_SETTABLE="RESOLVER_PROVIDER RESOLVER_MODEL RESOLVER_TIMEOUT_MIN PUSH RUN_CHECK_CHANGED"
CONFIG_READABLE="FORK_URL FORK_BRANCH UPSTREAM_URL UPSTREAM_BRANCH FEED_PORT LABEL_PREFIX SCHEDULE_HOUR
SCHEDULE_MINUTE RUN_AT_LOGIN PUSH RESOLVER_PROVIDER RESOLVER_MODEL RESOLVER_TIMEOUT_MIN RUN_CHECK_CHANGED MODE
ICON SIDE_APP_NAME SIDE_BUNDLE_ID SIDE_USER_DATA_NAME SIDE_T3_HOME SIDE_PORT APP_NAME APPS_DIR USERDATA_DIR
UPDATER_CACHE_DIR_NAME KEEP_BUILDS SEQ_START TOOL_PATH"

config_usage() {
  cat <<EOF2
Usage: t3code-diy config get <KEY>
       t3code-diy config set <KEY> <VALUE> [<KEY> <VALUE> ...]

set changes (all pairs are checked before anything is written):
  RESOLVER_PROVIDER     claude or codex; its CLI must be installed and logged in
  RESOLVER_MODEL        a model name such as opus or gpt-5.5; '' = the CLI's default
  RESOLVER_TIMEOUT_MIN  minutes the resolver may run, 5-600
  PUSH                  1 pushes the rebased branch to your fork, 0 doesn't
  RUN_CHECK_CHANGED     1 runs upstream's vp run check:changed in the test gate, 0 doesn't

get reads any scalar setting: $(echo "$CONFIG_READABLE" | tr '\n' ' ')
EOF2
}

in_list() { case " $(echo "$2" | tr '\n' ' ') " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

cmd_config() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    get)
      [ $# = 1 ] || { config_usage >&2; return 2; }
      in_list "$1" "$CONFIG_READABLE" || { echo "unknown setting: $1" >&2; return 2; }
      load_config
      printf '%s\n' "${!1}"
      ;;
    set)
      [ $# -ge 2 ] && [ $(($# % 2)) = 0 ] || { config_usage >&2; return 2; }
      load_config
      local key value pairs=("$@") i provider_changed=0
      for ((i = 0; i < ${#pairs[@]}; i += 2)); do
        key="${pairs[i]}"; value="${pairs[i + 1]}"
        in_list "$key" "$CONFIG_SETTABLE" || { echo "$key can't be set here (settable: $CONFIG_SETTABLE)" >&2; return 2; }
        case "$key" in
          RESOLVER_PROVIDER) valid_resolver_provider "$value" || { echo "RESOLVER_PROVIDER must be claude or codex" >&2; return 2; }
            [ "$value" != "$RESOLVER_PROVIDER" ] && provider_changed=1 ;;
          RESOLVER_MODEL) valid_resolver_model "$value" || { echo "RESOLVER_MODEL '$value' is not a model name" >&2; return 2; } ;;
          RESOLVER_TIMEOUT_MIN) valid_resolver_timeout "$value" || { echo "RESOLVER_TIMEOUT_MIN must be 5-600" >&2; return 2; } ;;
          PUSH | RUN_CHECK_CHANGED) case "$value" in 0 | 1) ;; *) echo "$key must be 0 or 1" >&2; return 2 ;; esac ;;
        esac
        printf -v "$key" '%s' "$value"
      done
      if [ "$provider_changed" = 1 ]; then
        local problem
        problem="$(resolver_problem "$RESOLVER_PROVIDER")"
        [ -z "$problem" ] || { echo "can't switch the resolver to $RESOLVER_PROVIDER: $problem" >&2; return 1; }
      fi
      write_config
      echo "saved to $DIY_CONFIG"
      ;;
    -h | --help | help | "") config_usage ;;
    *) echo "unknown config command: $sub" >&2; config_usage >&2; return 2 ;;
  esac
}
