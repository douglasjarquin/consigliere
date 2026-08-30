#!/bin/sh
# Build cs, csd, cs-runner, and the OTP release into PREFIX.
# The installed tree does not need Mix, source, or a repo checkout.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREFIX=${1:-"$ROOT/prefix"}
export PATH="/opt/homebrew/opt/erlang/bin:/usr/bin:/bin:/usr/local/bin:${PATH:-}"

mkdir -p "$PREFIX"
PREFIX=$(CDPATH= cd -- "$PREFIX" && pwd)
mkdir -p "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/share/consigliere"

(cd "$ROOT/runner/cs-runner" && go build -o "$ROOT/daemon/priv/cs-runner" .)
(cd "$ROOT/cli" && go build -o "$PREFIX/bin/cs" ./cmd/cs && go build -o "$PREFIX/bin/csd" ./cmd/csd && go build -o "$ROOT/daemon/priv/cs-attempt" ./cmd/cs-attempt)

(
  cd "$ROOT/daemon"
  mix deps.get
  MIX_ENV=prod mix clean
  rm -rf "$ROOT/daemon/_build/prod/rel/consigliere_daemon"
  MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix release --overwrite
)

rm -rf "$PREFIX/libexec/consigliere_daemon"
cp -R "$ROOT/daemon/_build/prod/rel/consigliere_daemon" "$PREFIX/libexec/consigliere_daemon"
cp "$ROOT/docs/cutover.md" "$PREFIX/share/consigliere/cutover.md"
cp "$ROOT/docs/cutover.md" "$ROOT/daemon/_build/prod/rel/consigliere_daemon/lib/"consigliere_daemon-*/priv/cutover.md 2>/dev/null || true

printf 'installed cs and csd to %s\n' "$PREFIX"
