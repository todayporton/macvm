#!/bin/bash
# Installs (or upgrades) macvm into ~/.local, or PREFIX if set. Safe to re-run.
# It does not touch the VM, ~/.ssh or Tart; `macvm setup` does the rest.
set -euo pipefail
cd "$(dirname "$0")"
prefix=${PREFIX:-$HOME/.local}
make install PREFIX="$prefix"
echo "installed $prefix/bin/macvm"
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "note: add $prefix/bin to PATH" ;; esac
echo "next: macvm setup"
