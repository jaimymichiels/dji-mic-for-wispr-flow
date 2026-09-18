#!/usr/bin/env bash
# Permission-free check of the native route: applies the DJI-only F18 mapping, listens for
# F18 the way hs.hotkey does, and logs output-volume changes. Volume is lowered to 90 so a
# leaked volume-up is visible; volume and mapping are both restored on any exit.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
f18_listener="$repository_root/build/f18_listener"
duration_seconds="${1:-150}"
dji_matching='{"VendorID":0x2CA3,"ProductID":0x4011}'
dji_key_mapping='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000E9,"HIDKeyboardModifierMappingDst":0x70000006D},{"HIDKeyboardModifierMappingSrc":0xC000000EA,"HIDKeyboardModifierMappingDst":0x70000006D}]}'

# This test owns F18 and clears the DJI mapping on exit, both of which would break a
# running dji_wispr module.
if pgrep -x Hammerspoon >/dev/null; then
  echo "Quit Hammerspoon first: this test registers F18 itself and clears the DJI mapping on exit." >&2
  exit 1
fi
if [[ ! -x "$f18_listener" ]]; then
  echo "Missing $f18_listener; run 'just build'." >&2
  exit 1
fi

original_volume="$(osascript -e 'output volume of (get volume settings)')"
volume_logger_pid=""

restore_system_state() {
  if [[ -n "$volume_logger_pid" ]]; then
    kill "$volume_logger_pid" 2>/dev/null || true
  fi
  hidutil property --matching "$dji_matching" --set '{"UserKeyMapping":[]}' >/dev/null
  osascript -e "set volume output volume $original_volume"
  echo "$(date +%T) restored: DJI mapping cleared, output volume=$original_volume"
}
trap restore_system_state EXIT
trap 'exit 143' TERM INT

log_volume_changes() {
  local previous_volume="" current_volume
  while true; do
    current_volume="$(osascript -e 'output volume of (get volume settings)')"
    if [[ "$current_volume" != "$previous_volume" ]]; then
      echo "$(date +%T) output volume=$current_volume"
      previous_volume="$current_volume"
    fi
    sleep 0.3
  done
}

# hidutil exits 0 with empty output when --matching finds nothing, so check the echoed row.
mapping_output="$(hidutil property --matching "$dji_matching" --set "$dji_key_mapping")"
if ! grep -qE '^[0-9a-f]+ +UserKeyMapping' <<<"$mapping_output"; then
  echo "Mapping matched no DJI HID service; is the receiver plugged in over USB-C?" >&2
  exit 1
fi
echo "$(date +%T) DJI mapping applied (volume up/down -> F18)"
echo "Press the transmitter button twice, then your keyboard's volume-up once (${duration_seconds}s window)."
osascript -e 'set volume output volume 90'
log_volume_changes &
volume_logger_pid=$!
"$f18_listener" "$duration_seconds"
