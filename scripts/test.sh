#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"

cd "$repo_dir"
swift test --disable-xctest
