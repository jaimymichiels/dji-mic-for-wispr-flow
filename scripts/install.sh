#!/usr/bin/env bash
# Symlinks the module into ~/.hammerspoon so this repository stays the source of truth, and
# appends the two require lines to init.lua only if they're missing, leaving the rest alone.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
module_source="$repository_root/hammerspoon/dji_wispr.lua"
hammerspoon_directory="$HOME/.hammerspoon"
module_link="$hammerspoon_directory/dji_wispr.lua"
init_file="$hammerspoon_directory/init.lua"
hammerspoon_cli="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"

mkdir -p "$hammerspoon_directory"
if [[ -e "$module_link" && ! -L "$module_link" ]] && ! cmp -s "$module_link" "$module_source"; then
  backup_path="$module_link.backup-$(date +%Y%m%d%H%M%S)"
  mv "$module_link" "$backup_path"
  echo "Existing module differed from the repository; moved it to $backup_path"
fi
ln -sfn "$module_source" "$module_link"
echo "Linked $module_link -> $module_source"

touch "$init_file"
for required_line in 'require("hs.ipc")' 'require("dji_wispr").start()'; do
  if ! grep -qxF "$required_line" "$init_file"; then
    printf '%s\n' "$required_line" >> "$init_file"
    echo "Added to init.lua: $required_line"
  fi
done

if pgrep -x Hammerspoon >/dev/null && [[ -x "$hammerspoon_cli" ]]; then
  # Reload on a timer so the CLI call returns before the Lua state it's talking to is torn down.
  "$hammerspoon_cli" -c 'hs.timer.doAfter(0.2, hs.reload)' >/dev/null
  echo "Reloaded Hammerspoon config"
else
  echo "Hammerspoon isn't running (or hs.ipc isn't loaded yet); open Hammerspoon to load the module"
fi
