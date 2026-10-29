#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
scripts/swiftw build --product DeskRecallChecks
binary_dir="$(scripts/swiftw build --show-bin-path)"
exec "$binary_dir/DeskRecallChecks"
