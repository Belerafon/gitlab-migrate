# lib/state.sh
ask_yes_no() {
  local q="$1" def="${2:-n}" a
  local prompt="[y/N]"; [ "$def" = "y" ] && prompt="[Y/n]"
  read -r -p "$q $prompt " a || true
  a="${a:-$def}"
  [[ "$a" =~ ^[Yy]$ ]]
}

state_init() { [ -f "$STATE_FILE" ] || echo "# gitlab migration state" > "$STATE_FILE"; }
state_clear(){ rm -f "$STATE_FILE"; echo "# gitlab migration state" > "$STATE_FILE"; }
get_state()  { [ -f "$STATE_FILE" ] && grep -E "^$1=" "$STATE_FILE" | tail -n1 | cut -d= -f2- || true; }
set_state()  {
  local k="$1" v="$2" tmp
  v="${v//$'\n'/ }"
  tmp="$(mktemp)"
  grep -v -E "^${k}=" "$STATE_FILE" 2>/dev/null > "$tmp" || true
  printf "%s=%s\n" "$k" "$v" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}
