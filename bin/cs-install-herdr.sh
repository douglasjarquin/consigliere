#!/usr/bin/env bash
# cs-install-herdr.sh - install CI's pinned, verified Herdr build.
#
# Single owner of the exact Herdr version, the official release asset URL, and
# the SHA-256 pin used by the required real-Herdr CI lane. Never installs a
# floating package-manager latest.
#
# The protocol floor is NOT owned here: it is read from bin/cs-herdr-lib.sh
# (CS_HERDR_MIN_PROTOCOL), the one authority that consigliere's runtime also
# gates on, so the installed build can never satisfy CI while failing the
# runtime floor. The pinned version is documented in docs/herdr.md
# ("Verified against herdr 0.8.0 (protocol 19)").
#
# Usage:
#   cs-install-herdr.sh <destination-directory>
#
# Pins Herdr v0.8.0 (protocol 19). Selects the official GitHub Releases asset
# for the host OS/arch, downloads with a bounded max size, verifies SHA-256
# before install, then refuses to finish unless the binary reports the exact
# pin version and a client protocol at or above the required floor.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exact pin - change only with a re-verified real-Herdr matrix and docs/herdr.md.
CS_HERDR_CI_VERSION=0.8.0
CS_HERDR_CI_TAG="v${CS_HERDR_CI_VERSION}"
# Bounded download ceiling (bytes). The largest official 0.8.0 asset is under 22 MiB.
CS_HERDR_CI_MAX_BYTES=25000000
CS_HERDR_CI_REPO=ogulcancelik/herdr

die() {
  printf 'cs-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

# Read the protocol floor from its single runtime owner so this installer and
# cs-herdr-lib.sh can never disagree about what "supported" means.
CS_HERDR_CI_MIN_PROTOCOL=$(
  awk -F= '/^CS_HERDR_MIN_PROTOCOL=/ { gsub(/[^0-9]/, "", $2); print $2; exit }' \
    "$ROOT/bin/cs-herdr-lib.sh"
)
case "$CS_HERDR_CI_MIN_PROTOCOL" in
  ''|*[!0-9]*) die "could not read CS_HERDR_MIN_PROTOCOL from bin/cs-herdr-lib.sh" ;;
esac

DESTINATION=${1:?usage: cs-install-herdr.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    SHA256=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    SHA256=f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    SHA256=d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    SHA256=77cb5afd6c8fcaaaf3bc28e474ec01c209331ad08094e20d7f8aa9b0bb78d649
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${CS_HERDR_CI_REPO}/releases/download/${CS_HERDR_CI_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cs-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'cs-install-herdr.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$CS_HERDR_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $CS_HERDR_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Herdr asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/herdr"

# Post-install version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$CS_HERDR_CI_VERSION" ] \
  || die "installed herdr version is '${installed_version:-<empty>}', expected exact pin $CS_HERDR_CI_VERSION"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$CS_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $CS_HERDR_CI_MIN_PROTOCOL"

printf 'cs-install-herdr.sh: installed herdr %s (protocol %s, floor %s) to %s\n' \
  "$installed_version" "$protocol" "$CS_HERDR_CI_MIN_PROTOCOL" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
