#!/usr/bin/env bash
# Install self-contained files, preserving the rest of the Hammerspoon config.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
hammerspoon_directory="${DJI_HAMMERSPOON_DIR:-$HOME/.hammerspoon}"
hammerspoon_cli="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
battery_only=false
reload=true

for argument in "$@"; do
  case "$argument" in
    --battery-only) battery_only=true ;;
    --no-reload) reload=false ;;
    *) echo "Usage: $0 [--battery-only] [--no-reload]" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$repository_root/build/dji_battery" ]]; then
  echo "Build the battery reader first: just build-battery" >&2
  exit 1
fi
mkdir -p "$hammerspoon_directory/bin" "$hammerspoon_directory/assets"

install_file() {
  local source_file="$1" destination_file="$2" mode="$3"
  local staged_file backup_path
  if [[ -f "$destination_file" && ! -L "$destination_file" ]] && cmp -s "$source_file" "$destination_file"; then
    chmod "$mode" "$destination_file"
    return
  fi
  # Rename a staged copy over the destination so old symlinks are replaced,
  # rather than writing through them into another checkout.
  staged_file="$(mktemp "$destination_file.tmp.XXXXXX")"
  if ! install -m "$mode" "$source_file" "$staged_file"; then
    rm -f "$staged_file"
    return 1
  fi
  if [[ -e "$destination_file" && "$destination_file" == *.lua ]] && ! cmp -s "$source_file" "$destination_file"; then
    backup_path="$destination_file.backup-$(date +%Y%m%d%H%M%S)"
    if ! cp -p "$destination_file" "$backup_path"; then
      rm -f "$staged_file"
      return 1
    fi
    echo "Backed up existing module to $backup_path"
  fi
  if ! mv -f "$staged_file" "$destination_file"; then
    rm -f "$staged_file"
    return 1
  fi
}

install_file "$repository_root/build/dji_battery" "$hammerspoon_directory/bin/dji_battery" 755
install_file "$repository_root/hammerspoon/assets/dji-logo.svg" "$hammerspoon_directory/assets/dji-logo.svg" 644
install_file "$repository_root/hammerspoon/dji_battery.lua" "$hammerspoon_directory/dji_battery.lua" 644
if [[ "$battery_only" == false ]]; then
  install_file "$repository_root/hammerspoon/dji_wispr.lua" "$hammerspoon_directory/dji_wispr.lua" 644
elif [[ -L "$hammerspoon_directory/dji_wispr.lua" && -f "$hammerspoon_directory/dji_wispr.lua" ]]; then
  # Preserve installed dictation customizations while removing legacy worktree links.
  install_file "$hammerspoon_directory/dji_wispr.lua" "$hammerspoon_directory/dji_wispr.lua" 644
fi

init_file="$hammerspoon_directory/init.lua"
touch "$init_file"
required_lines=('require("hs.ipc")')
if [[ "$battery_only" == false ]]; then required_lines+=('require("dji_wispr").start()'); fi
required_lines+=('require("dji_battery").start()')
for required_line in "${required_lines[@]}"; do
  if ! grep -qxF "$required_line" "$init_file"; then
    # Keep the new statement out of an existing final line comment.
    if [[ -s "$init_file" && -n "$(tail -c 1 "$init_file")" ]]; then
      printf '\n' >> "$init_file"
    fi
    printf '%s\n' "$required_line" >> "$init_file"
  fi
done

echo "Installed DJI Mic files in $hammerspoon_directory"
if [[ "$reload" == true ]] && pgrep -x Hammerspoon >/dev/null && [[ -x "$hammerspoon_cli" ]]; then
  if [[ "$battery_only" == true ]]; then
    reload_code='if package.loaded.dji_battery then package.loaded.dji_battery.stop() end; package.loaded.dji_battery = nil; require("dji_battery").start()'
  else
    # Let IPC return before the current Lua state is torn down.
    reload_code='hs.timer.doAfter(0.2, hs.reload)'
  fi
  if "$hammerspoon_cli" -c "$reload_code"; then
    echo "Hammerspoon configuration updated"
  else
    echo "Files installed. Choose Reload Config from the Hammerspoon menu to activate them."
  fi
else
  echo "Open Hammerspoon or reload its config to activate the installed files."
fi
