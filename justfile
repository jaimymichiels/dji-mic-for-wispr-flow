set shell := ["bash", "-euo", "pipefail", "-c"]

build_directory := justfile_directory() / "build"
public_repository := "saqibnizami/dji-mic-for-wispr-flow"

# List recipes
default:
    @just --list

# Compile the Swift diagnostic probes into build/
build:
    mkdir -p "{{build_directory}}"
    swiftc -O -o "{{build_directory}}/sender_probe" probes/sender_probe.swift
    swiftc -O -o "{{build_directory}}/f18_listener" probes/f18_listener.swift
    swiftc -O -o "{{build_directory}}/mic_in_use" probes/mic_in_use.swift

# Symlink the module into ~/.hammerspoon and reload Hammerspoon
install:
    scripts/install.sh

# Permission-free check that the DJI button arrives as F18 (quit Hammerspoon first)
test-remap seconds="150": build
    scripts/test_native_remap.sh {{seconds}}

# Two-phase sender-ID + remap probe; needs Input Monitoring for the terminal (quit Hammerspoon first)
probe seconds="15": build
    scripts/probe_sender_and_remap.sh {{seconds}}

# Show which input devices are being captured right now
mic-in-use: build
    "{{build_directory}}/mic_in_use"

# Show the UserKeyMapping currently applied to the DJI receiver
mapping:
    hidutil property --matching '{"VendorID":0x2CA3,"ProductID":0x4011}' --get UserKeyMapping

# Show dji_wispr lines from the running Hammerspoon console
console:
    /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'hs.console.getConsole()' | grep dji_wispr

# Lint the scripts, syntax-check the module, validate the Karabiner rules and diagrams
lint:
    shellcheck scripts/*.sh
    luajit -e "assert(loadfile('hammerspoon/dji_wispr.lua'))"
    python3 -m json.tool karabiner/dji_mic_wispr.json >/dev/null
    xmllint --noout docs/images/*.svg

# The public repo is a sanitized mirror, never a branch of this one: its history must never
# contain internal references or AI attribution, so nothing is pushed between the repos
# directly. See docs/internal/RELEASING.md.

# Build the sanitized public mirror in a temp directory, gate it, and list what would ship (no network)
check-public:
    #!/usr/bin/env bash
    set -euo pipefail
    mirror_directory="$(mktemp -d)"
    trap 'rm -rf "$mirror_directory"' EXIT
    just _mirror-into "$mirror_directory"
    (cd "$mirror_directory" && find . -type f -not -path './.git/*' | sort)
    echo "gate passed: no denylisted tokens in the public mirror"

# Mirror the committed private tree to the public repo's main branch (gated, one fixed-message commit)
sync-public:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit or stash private changes first: the mirror is built from the working tree." >&2
        exit 1
    fi
    private_commit="$(git rev-parse --short HEAD)"
    public_clone="$(mktemp -d)"
    trap 'rm -rf "$public_clone"' EXIT
    git clone --quiet "https://github.com/{{public_repository}}.git" "$public_clone"
    just _mirror-into "$public_clone"
    cd "$public_clone"
    git checkout --quiet -B main
    if [[ -z "$(git status --porcelain)" ]]; then
        echo "public already in sync"
        exit 0
    fi
    git add -A
    git commit --quiet -m "sync: source parity with dev repo @ ${private_commit}"
    git push --quiet origin main
    echo "pushed $(git rev-parse --short HEAD) to {{public_repository}}"

# Copy the sanitized tree into DIRECTORY, then abort if any denylisted token is present
_mirror-into directory:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f .sanitize-denylist ]]; then
        echo "missing .sanitize-denylist" >&2
        exit 1
    fi
    denylist_pattern="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' .sanitize-denylist | paste -sd '|' -)"
    rsync -a --delete \
        --exclude='.git' --exclude='build' --exclude='/docs/internal' \
        --exclude='.sanitize-denylist' --exclude='.DS_Store' \
        ./ "{{directory}}"/
    if grep -rnE --exclude-dir=.git "$denylist_pattern" "{{directory}}"; then
        echo "ABORT: internal tokens present in public mirror" >&2
        exit 1
    fi
