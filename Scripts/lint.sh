#!/bin/bash
set -euo pipefail

if rg -n 'try!|fatalError\(' Sources Tests; then
  echo "Unsafe Swift construct found." >&2
  exit 1
fi

swift build
