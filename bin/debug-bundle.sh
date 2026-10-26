#!/bin/zsh
# Unpacks a debug bundle into Artifacts/DebugBundles, symbolicates its stacks and prints summary.md.
exec python3 -I "${0:A:h}/debug_bundle.py" "$@"
