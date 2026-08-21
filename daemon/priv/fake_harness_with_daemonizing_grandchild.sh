#!/bin/sh
# Stands in for a real coding-harness process that itself spawns a
# self-daemonizing grandchild (calls setsid() and escapes the harness's
# own process group), for the daemonize-escape fix's live tmux evidence.
# Usage: fake_harness_with_daemonizing_grandchild.sh <heartbeat-file> <daemonizing-binary> <daemonizing-binary-env-value> <grandchild-pid-file>
set -eu
heartbeat_file="$1"
daemonizing_binary="$2"
daemonizing_env_value="$3"
grandchild_pid_file="$4"

env "CS_RUNNER_TEST_HELPER=$daemonizing_env_value" "$daemonizing_binary" &
echo $! > "$grandchild_pid_file"

i=0
while :; do
  i=$((i + 1))
  printf 'heartbeat %s\n' "$i"
  printf '%s %s\n' "$$" "$i" > "$heartbeat_file"
  sleep 0.2
done
