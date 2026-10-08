#!/usr/bin/env bash
# Update the battery indicator without reloading active dictation controls.
set -euo pipefail
script_directory="$(cd "$(dirname "$0")" && pwd)"
exec "$script_directory/install.sh" --battery-only "$@"
