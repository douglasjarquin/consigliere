# Dev-tools suite: mise + aube + container dev/CI/Cloud Agents

This is a mostly additive dev-tools suite on top of consigliere's own bash-script tooling.
The existing CI lane map routes `.cursor/environment.json` into the portable contract suite.
It gives Mac Compose, CI, and Cursor Cloud Agents one reproducible container-based environment - `mise` for tooling/tasks, `aube` for the JS package-manager work that needs it, and Docker for one shared image - inspired by (not copied from) the boss's `niceuptime` project's own mid-implementation container setup.

## Layout

- `mise.toml` (root) - pins `node` and `aube` (`2.1`) for this suite's own project-scoped tooling.
  `tasks-axi` (`0.2.4`, matching `bin/cs-deps-lib.sh`'s `CS_TASKS_AXI_MIN` floor) is pinned separately, via mise's GLOBAL config inside the image (see below) - a project-scoped tool's shim only activates in a directory `mise.toml` governs, but tests invoke `tasks-axi` from scratch fixture directories with no `mise.toml` of their own.
  It does not replace `bin/cs-deps-lib.sh`, which stays the single owner of consigliere's own required/optional tool floors for the human/doctor-check path.
  The two are independent, compatible mechanisms: `mise.toml` governs what's baked into the container image; `cs-deps-lib.sh` governs what a human running consigliere directly needs on their own machine.
- `mise-tasks/dev/{install,up,down,shell,test}` - file-based mise tasks (namespaced `dev:*`), each a thin composition of already-built pieces (a mise task invoking a `docker compose` command), never a duplicate of logic that already lives in `bin/cs-test-run.sh` or `docker-compose.yml`.
- `docker/dev/Dockerfile` - a single image for Mac Compose, CI, and Cursor Cloud Agents.
  It is deliberately not split into a toolchain image and a dev image because that split was flagged in niceuptime as needing manual synchronization.
  It installs the toolchain `bin/cs-test-run.sh --portable` needs (bash, git, jq, sqlite3, python3, gh, lsof, and sudo), a pinned ShellCheck via `bin/cs-install-shellcheck.sh` (reused as-is, not modified), and a SHA-pinned `mise` bootstrap that installs `node`/`aube` per `mise.toml` and `node`/`tasks-axi` again via mise's global config.
  It copies only `mise.toml`, `bin/cs-install-shellcheck.sh`, and `bin/cs-lint.sh` while building the pinned tools, because Cursor checks out the project separately.
  It keeps the runtime user non-root and exposes mise tools through the runtime user's `.bashrc` and `/usr/local/bin` shims so Cursor's session PATH reset cannot hide them.
- `docker-compose.yml` (root) - `dev` service (the toolchain/test container) and `web` service (see "The web placeholder" below).
- `.dockerignore` - excludes `config/`, `host/`, `data/`, `state/`, `projects/`, `.no-mistakes/`, and `.made/evidence/` from the build context, so none of that gitignored, boss-private content is ever baked into an image layer, regardless of what happens to exist on disk when the image is built.
- `scripts/ci/run-in-container.sh` - builds the `dev` image and runs a given command inside it.
  Adapted from niceuptime's own `scripts/ci/run-in-dev-container.sh` wrapper pattern.

## Local usage

- `mise run dev:install` - build the `dev` and `web` images.
- `mise run dev:up` - bring up the local dev stack.
- `mise run dev:shell` - open an interactive shell inside the `dev` container.
- `mise run dev:test` - run consigliere's existing portable test suite (`bin/cs-test-run.sh --portable`, unmodified) inside the `dev` container.
- `mise run dev:down` - tear down the local dev stack.

## Cursor Cloud Agents

Cursor Cloud Agents use the same `docker/dev/Dockerfile` through `.cursor/environment.json`.
The configuration's `build.dockerfile` is `../docker/dev/Dockerfile` and its `build.context` is `..`, both relative to `.cursor/` with `..` special-cased by Cursor as the repository root.
Cursor checks out the requested commit into the workspace, so the Dockerfile copies only the files needed to bake the pinned tools and never copies the full project.
The `install` command is `mise install`, which Cursor runs from the project root after checkout for an idempotent dependency refresh.
There is no `start` command because this repository has no Cloud Agent service that must remain running between commands.
The image includes `git`, passwordless `sudo` for the non-root runtime user, default `UID`/`GID` values of `1000`, and PATH persistence that survives Cursor's session environment reset.

## Mount-masking: why the seven sensitive paths can never leak

`config/`, `host/`, `data/`, `state/`, `projects/`, `.no-mistakes/`, and `.made/evidence/` are this repo's gitignored, boss-private operational state (`docs/configuration.md` owns the complete layout).
Two independent protections keep them out of the dev-tools suite entirely:

1. `.dockerignore` excludes all seven from the Docker build context, so `docker/dev/Dockerfile`'s `COPY . /workspace` step can never bake their real content into any image layer, no matter what exists in the directory the image is built from.
2. `docker-compose.yml`'s `dev` service mounts the repo root read-write, then mounts an anonymous (empty, ephemeral) volume over each of the seven paths inside the container - a standard Compose masking technique.
   Even if a bind-mounted host directory has real content, the container's view of those seven paths stays empty.

The `web` service needs neither protection: it mounts only `./web:/srv/web:ro`, nothing else.

## The web placeholder

Consigliere itself has no web frontend today.
The boss asked for the container to be generically web-capable anyway, in case that changes later, so `web/index.html` is a fixed, minimal placeholder page, served by the `web` Compose service on port 8080 (`python3 -m http.server`).
It is not real product content - just a reserved, testable slot.

## CI

`.github/workflows/ci.yml`'s `lint`, `test-coverage`, and `portable` jobs stay on `ubuntu-latest`, but `portable` and `test-coverage` now run their `bin/cs-test-run.sh` invocation through `scripts/ci/run-in-container.sh`, inside the same `dev` image the Mac Compose workflow and Cursor Cloud Agents use.
`lint` itself is unaffected - `bin/cs-lint.sh`'s canonical glob set already covers the new `scripts/ci/*.sh` and `mise-tasks/dev/*` files directly on the runner.

Two jobs are deliberately **not** containerized:

- **`herdr`** - this lane runs a real herdr server on the bare runner and drives it as a client over a host-local socket (`docs/herdr.md`).
  Wrapping only the client command through the dev-tools container would split the client from a host-only server, a real connectivity break, not a cosmetic one.
- **`invariants`** - this job is a structural git/tracked-path check with no dependency on the dev toolchain at all, and it must stay completely unconditional (no `needs:`, no `if:`) so it runs on every change including a docs-only one.
  There is nothing to gain by containerizing it.

A new **`real-docker`** job proves the dev-tools suite's own pieces work: it installs `mise`, runs `dev:install`/`dev:up`, curls the placeholder web service, runs `bin/cs-test-run.sh --docker` (which runs `tests/cs-dev-tools.test.sh`), then tears the stack down.
It runs bare, not through `scripts/ci/run-in-container.sh` - its whole purpose is building and running the dev-tools containers, so wrapping it in another container would be Docker-in-Docker for no reason.

None of this shares an image build across jobs, and none of it pushes to a registry: each containerized job builds its own image as a step (`docker compose build dev`, Docker's ordinary layer cache), with no shared build job and no `packages: write` permission.

## Provenance

This suite is new work, inspired by (not copied from) the boss's `niceuptime` project's mid-implementation container setup, which itself is not part of this repo.
There is no ongoing sync between the two: this suite evolves independently once it lands.
