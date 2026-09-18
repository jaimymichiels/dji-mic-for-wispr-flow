#!/usr/bin/env bash
# Phase 1 answers "can an event tap attribute a media key to the DJI receiver?" using the
# private sender-ID route. Phase 2 answers "does the per-device hidutil remap turn the DJI's
# volume-up into F18?". Needs Input Monitoring for the terminal. The DJI mapping is cleared
# on any exit so a Ctrl-C can't leave the button remapped.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
sender_probe="$repository_root/build/sender_probe"
phase_seconds="${1:-15}"
dji_matching='{"VendorID":0x2CA3,"ProductID":0x4011}'
dji_key_mapping='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000E9,"HIDKeyboardModifierMappingDst":0x70000006D},{"HIDKeyboardModifierMappingSrc":0xC000000EA,"HIDKeyboardModifierMappingDst":0x70000006D}]}'

if pgrep -x Hammerspoon >/dev/null; then
  echo "Quit Hammerspoon first: this probe clears the DJI mapping on exit." >&2
  exit 1
fi
if [[ ! -x "$sender_probe" ]]; then
  echo "Missing $sender_probe; run 'just build'." >&2
  exit 1
fi

clear_mapping() {
  hidutil property --matching "$dji_matching" --set '{"UserKeyMapping":[]}' >/dev/null
  echo "[DJI UserKeyMapping cleared]"
}
trap clear_mapping EXIT

echo "=== Phase 1 (${phase_seconds}s): press the DJI transmitter button twice, then your keyboard's volume-up twice"
"$sender_probe" "$phase_seconds"

hidutil property --matching "$dji_matching" --set "$dji_key_mapping" >/dev/null
echo "=== Phase 2 (${phase_seconds}s): DJI volume up/down remapped to F18. Press the DJI button twice, then keyboard volume-up once"
"$sender_probe" "$phase_seconds"
