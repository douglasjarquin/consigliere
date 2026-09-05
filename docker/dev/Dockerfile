# docker/dev/Dockerfile - consigliere's dev-tools container image.
#
# Single image (deliberately not split into a toolchain image + a dev image -
# niceuptime's own dual-Dockerfile setup flagged that split as needing manual
# sync, a rough edge this image avoids). Installs the toolchain
# bin/cs-test-run.sh --portable needs, plus mise-managed node/aube/tasks-axi
# for the new dev-tooling tasks under mise-tasks/dev/. Never runs as root at
# container runtime - see the UID/GID build args below.
#
# docs/dev-environment.md is the source of truth for how this image is used by
# Mac Compose, CI, and Cursor Cloud Agents.

FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# archive.ubuntu.com intermittently serves a stale index mid-mirror-sync
# ("Hash Sum mismatch" / "Mirror sync in progress?"), failing apt-get update;
# apt's own Acquire::Retries covers that transient case.
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries

# Baseline toolchain bin/cs-test-run.sh --portable needs (matches
# .github/workflows/ci.yml's portable-lane "Require test tools" step: jq,
# python3, sqlite3), plus git/curl/ca-certificates/gnupg for the install
# steps below.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      git \
      jq \
      sqlite3 \
      python3 \
      curl \
      ca-certificates \
      gnupg \
      xz-utils \
      lsof \
      sudo \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh), via its official apt repository - no pinned-binary
# installer exists for it in bin/, unlike shellcheck/herdr/actionlint.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# UID/GID are passed in as whatever actually owns the bind-mounted checkout
# (the invoking host user, or the CI runner's checkout user) - see
# scripts/ci/run-in-container.sh. That number can collide with a base-image
# system account at any GID/UID (ubuntu:24.04 itself pre-creates a "ubuntu"
# user/group at 1000:1000, and low GIDs like 20 are already system groups),
# so whatever currently owns the target UID/GID is removed first, by name,
# rather than assuming it's always "ubuntu".
RUN set -eu; \
    existing_user="$(getent passwd "${UID}" | cut -d: -f1 || true)"; \
    [ -z "$existing_user" ] || userdel -r "$existing_user" 2>/dev/null || true; \
    existing_group="$(getent group "${GID}" | cut -d: -f1 || true)"; \
    [ -z "$existing_group" ] || groupdel "$existing_group"; \
    groupadd -g "${GID}" cs; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash cs

RUN printf 'cs ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/cs \
    && chmod 0440 /etc/sudoers.d/cs

RUN mkdir -p /usr/local/share/mise /usr/local/etc/mise \
    && chown -R cs:cs /usr/local/share/mise /usr/local/etc/mise

WORKDIR /workspace
COPY mise.toml /workspace/mise.toml
COPY bin/cs-install-shellcheck.sh /tmp/cs-dev-tools/bin/cs-install-shellcheck.sh
COPY bin/cs-lint.sh /tmp/cs-dev-tools/bin/cs-lint.sh
RUN chown cs:cs /workspace

# Pinned ShellCheck via this repo's own installer (bin/cs-lint.sh
# --required-version owns the exact pin; this never floats to latest).
RUN bash /tmp/cs-dev-tools/bin/cs-install-shellcheck.sh /usr/local/bin \
    && rm -rf /tmp/cs-dev-tools

# Pinned mise bootstrap: exact version, per-archive SHA-256 verified before
# install - the same posture bin/cs-install-herdr.sh already uses for herdr.
# Both archs are pinned since local dev runs arm64 (Apple Silicon Docker
# Desktop/OrbStack) while CI runs amd64 (GitHub-hosted ubuntu-latest).
# Re-verify both pins (curl the official SHASUMS256.txt for the target
# MISE_VERSION) before bumping MISE_VERSION.
ARG TARGETARCH
ARG MISE_VERSION=2026.9.1
ARG MISE_SHA256_AMD64=063dda9149ab6be53da877c2d176afe0eac68e64cf8ca295bd0528720701c65d
ARG MISE_SHA256_ARM64=98d2ea7b82dd966afdb8a9f4e9edbca771acf2a30d2842bfc0efdb7b61c886a3
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) mise_asset=linux-x64; mise_sha256="${MISE_SHA256_AMD64}" ;; \
      arm64) mise_asset=linux-arm64; mise_sha256="${MISE_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-${mise_asset}.tar.gz" \
      -o /tmp/mise.tar.gz; \
    echo "${mise_sha256}  /tmp/mise.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/mise.tar.gz -C /tmp; \
    install -m 0755 /tmp/mise/bin/mise /usr/local/bin/mise; \
    rm -rf /tmp/mise.tar.gz /tmp/mise

ENV MISE_DATA_DIR=/usr/local/share/mise
ENV MISE_CONFIG_DIR=/usr/local/etc/mise
ENV MISE_YES=1
ENV PATH="/usr/local/share/mise/shims:/usr/local/bin:${PATH}"
USER cs
RUN printf '%s\n' 'export PATH="/usr/local/share/mise/shims:$PATH"' >> /home/cs/.bashrc
# Installs node/aube per mise.toml, baked into the image rather than lazily
# fetched at container-run time. Runs as the non-root "cs" user, not root,
# since mise installs into the configured system-wide directories owned by
# the invoking user - installing as root here would leave the tools invisible
# to the "cs" user this image actually runs as.
RUN mise install

# Also installed via mise's GLOBAL config (/usr/local/etc/mise/config.toml),
# not just the project mise.toml: a project-scoped tool's shim only activates in
# a directory mise.toml governs, but bin/cs-test-run.sh's fixtures invoke
# tasks-axi (and its own shim needs node) from scratch directories under
# /tmp with no mise.toml of their own - tasks-axi needs to behave like the
# "npm install -g" it replaced, reachable from any cwd.
RUN mise use --global node@24 npm:tasks-axi@0.2.4

RUN mise reshim
USER root
RUN for tool in node npm npx aube tasks-axi; do \
      ln -sf "/usr/local/share/mise/shims/${tool}" "/usr/local/bin/${tool}"; \
    done
USER cs

# The actual work happens via `docker compose run`/`exec` (see
# mise-tasks/dev/* and scripts/ci/run-in-container.sh), not this image's own
# entrypoint - it just needs to stay alive for `docker compose up -d dev`.
CMD ["sleep", "infinity"]
