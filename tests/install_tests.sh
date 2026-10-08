#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT

config_directory="$test_directory/clean install"
mkdir -p "$config_directory"
printf '%s\n' '-- Existing configuration' > "$config_directory/init.lua"
DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/install.sh" --no-reload >/dev/null
for installed_file in dji_wispr.lua dji_battery.lua assets/dji-logo.svg bin/dji_battery; do
  [[ -f "$config_directory/$installed_file" && ! -L "$config_directory/$installed_file" ]]
done
[[ -x "$config_directory/bin/dji_battery" ]]
grep -qxF -- '-- Existing configuration' "$config_directory/init.lua"
cp "$config_directory/init.lua" "$test_directory/first-init.lua"
DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/install.sh" --no-reload >/dev/null
cmp -s "$test_directory/first-init.lua" "$config_directory/init.lua"
for required_line in 'require("hs.ipc")' 'require("dji_wispr").start()' 'require("dji_battery").start()'; do
  [[ "$(grep -cxF "$required_line" "$config_directory/init.lua")" == 1 ]]
done

for installer in install.sh install_battery.sh; do
  config_directory="$test_directory/no final newline-$installer"
  mkdir -p "$config_directory"
  printf '%s\n' 'require("hs.ipc")' 'require("dji_wispr").start()' > "$config_directory/init.lua"
  printf '%s' '-- Local configuration' >> "$config_directory/init.lua"
  DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/$installer" --no-reload >/dev/null
  grep -qxF -- '-- Local configuration' "$config_directory/init.lua"
  grep -qxF 'require("dji_battery").start()' "$config_directory/init.lua"
  cp "$config_directory/init.lua" "$test_directory/no-newline-$installer.lua"
  DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/$installer" --no-reload >/dev/null
  cmp -s "$test_directory/no-newline-$installer.lua" "$config_directory/init.lua"
done

legacy_directory="$test_directory/legacy"
config_directory="$test_directory/migrated install"
mkdir -p "$legacy_directory" "$config_directory"
printf '%s\n' '-- Custom dictation module' > "$legacy_directory/dji_wispr.lua"
printf '%s\n' '-- Old battery module' > "$legacy_directory/dji_battery.lua"
ln -s "$legacy_directory/dji_wispr.lua" "$config_directory/dji_wispr.lua"
ln -s "$legacy_directory/dji_battery.lua" "$config_directory/dji_battery.lua"
DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/install_battery.sh" --no-reload >/dev/null
[[ ! -L "$config_directory/dji_wispr.lua" && ! -L "$config_directory/dji_battery.lua" ]]
cmp -s "$legacy_directory/dji_wispr.lua" "$config_directory/dji_wispr.lua"
cmp -s "$repository_root/hammerspoon/dji_battery.lua" "$config_directory/dji_battery.lua"
grep -qxF -- '-- Old battery module' "$legacy_directory/dji_battery.lua"
backup_files=("$config_directory"/dji_battery.lua.backup-*)
[[ ${#backup_files[@]} == 1 ]]
cmp -s "$legacy_directory/dji_battery.lua" "${backup_files[0]}"
rm -rf "$legacy_directory"
[[ -f "$config_directory/dji_wispr.lua" && -x "$config_directory/bin/dji_battery" ]]
DJI_HAMMERSPOON_DIR="$config_directory" "$repository_root/scripts/install_battery.sh" --no-reload >/dev/null
grep -qxF -- '-- Custom dictation module' "$config_directory/dji_wispr.lua"
echo "Installation checks passed (copies, repeat updates, preserved config, missing final newline and symlink migration)."
