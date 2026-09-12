# keep numeric sleep commands working while adding the on/off shortcuts.
function agents() { "$HOME/.local/bin/agents" "$@"; }
function sleep() {
  case "${1-}" in
    on|off|status) agents "$@" ;;
    *) /bin/sleep "$@" ;;
  esac
}
