#!/usr/bin/env bash
# Materialize the published A snapshot into a NEW workspace, never the live ext tree.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -lt 1 || $# -gt 2 || ( $# == 2 && "$2" != --dfts-adapter ) ]]; then echo 'Usage: prepare-oai-worktree.sh NEW_ABSOLUTE_DIRECTORY [--dfts-adapter]' >&2; exit 2; fi
dest=$1
[[ "$dest" = /* && ! -e "$dest" ]] || { echo 'Destination must be absolute and absent' >&2; exit 2; }
[[ -d "$root/vendor/openairinterface5g" ]] || { echo 'Use the published repository containing vendor/openairinterface5g' >&2; exit 2; }
mkdir -p "$dest"
cp -a "$root/vendor/openairinterface5g/." "$dest/"
# Replace only the copied plugin symlink, never a directory or its target.
if [[ -L "$dest/plugins" ]]; then unlink "$dest/plugins"; fi
if [[ -e "$dest/plugins" ]]; then echo 'Unexpected plugin directory in snapshot; inspect destination' >&2; exit 1; fi
ln -s "$root/plugins" "$dest/plugins"
printf 'Prepared A snapshot at %s\nNo experimental patches applied; no build or service started.\n' "$dest"
if [[ "${2:-}" == --dfts-adapter ]]; then
  ln -s "$root/adapters" "$dest/adapters"
  git -C "$dest" apply --check "$root/patches/k3-A-dfts-extraction.patch"
  git -C "$dest" apply "$root/patches/k3-A-dfts-extraction.patch"
  echo 'Applied the A DFT architecture extraction patch only.'
fi
