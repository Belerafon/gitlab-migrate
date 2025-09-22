# lib/log.sh
log()  { echo -e "$*" >&2; }
ok()   { echo -e "[✔] $*" >&2; }
warn() { echo -e "[! ] $*" >&2; }
err()  { echo -e "[✘] $*" >&2; }

format_duration() {
  local seconds="${1:-0}"

  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf "%s" "$seconds"
    return
  fi

  local hours minutes secs
  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  secs=$((seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%02d:%02d:%02d (%ds)" "$hours" "$minutes" "$secs" "$seconds"
  else
    printf "%02d:%02d (%ds)" "$minutes" "$secs" "$seconds"
  fi
}
