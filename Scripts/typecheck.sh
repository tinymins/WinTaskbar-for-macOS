#!/bin/bash
set -euo pipefail

swift build
swift run --skip-build WinTaskbar --self-test
