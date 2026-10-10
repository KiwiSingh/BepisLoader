#!/bin/bash
# Retained entry point; use the root script so packaging cannot copy to Downloads.
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../.." && pwd)/inject_icon.sh" "$@"
