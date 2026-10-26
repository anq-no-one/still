#!/bin/zsh
# Bug reports this Mac collected into ~/Downloads/Still Bug Reports: list, open <name|latest>, done <name|all>.
exec python3 -I "${0:A:h}/debug_bundle.py" reports "$@"
