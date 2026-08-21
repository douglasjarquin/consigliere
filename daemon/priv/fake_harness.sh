#!/bin/sh
# Stands in for a real coding-harness process for Phase 0 Spike B.
# Usage: fake_harness.sh <heartbeat-file-path> [max-iterations]
# With max-iterations given, exits 0 cleanly after that many heartbeats
# instead of looping forever, so a test can exercise the clean-exit path.
set -eu
heartbeat_file="$1"
max_iterations="${2:-0}"
i=0
while :; do
  i=$((i + 1))
  printf 'heartbeat %s\n' "$i"
  printf '%s %s\n' "$$" "$i" > "$heartbeat_file"
  if [ "$max_iterations" -gt 0 ] && [ "$i" -ge "$max_iterations" ]; then
    exit 0
  fi
  sleep 0.2
done
