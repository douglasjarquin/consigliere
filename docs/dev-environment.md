# Dev-tools suite: mise + aube + container dev/CI

This is a purely additive dev-tools suite on top of consigliere's own bash-script tooling.
No existing `bin/*.sh` script's content changed to add it.
It exists to give consigliere its own reproducible, container-based dev environment and CI path - `mise` for tooling/tasks, `aube` for the JS package-manager work that needs it, and Docker for a single dev/CI image - inspired by (not copied from) the boss's `niceuptime` project's own mid-implementation container setup.

## Layout

- `mise.toml` (root) - pins `node` and `aube` (`2.1`) for this suite's own project-scoped tooling.
  `tasks-axi` (`0.2.4`, matching `bin/cs-deps-lib.sh`'s `CS_TASKS_AXI_MIN` floor) is pinned separately, via mise's GLOBAL config inside the image (see below) - a project-scoped tool's shim only activates in a directory `mise.toml` governs, but tests invoke `tasks-axi` from scratch fixture directories with no `mise.toml` of their own.
  It does not replace `bin/cs-deps-lib.sh`, which stays the single owner of consigliere's own required/optional tool floors for the human/doctor-check path.
  The two are independent, compatible mechanisms: `mise.toml` governs what's baked into the container image; `cs-deps-lib.sh` governs what a human running consigliere directly needs on their own machine.
- `mise-tasks/dev/{install,up,down,shell,test}` - file-based mise tasks (namespaced `dev:*`), each a thin composition of already-built pieces (a mise task invoking a `docker compose` command), never a duplicate of logic that already lives in `bin/cs-test-run.sh` or `docker-compose.yml`.
- `docker/dev/Dockerfile` - a single image (deliberately not split into a toolchain image and a dev image the way niceuptime's own setup is - that split was flagged there as needing manual sync, a rough edge this image avoids).
  Installs the toolchain `bin/cs-test-run.sh --portable` needs (bash, git, jq, sqlite3, python3, gh, lsof), a pinned ShellCheck via `bin/cs-install-shellcheck.sh` (reused as-is, not modified), and a SHA-pinned `mise` bootstrap that then installs `node`/`aube` per `mise.toml` and `node`/`tasks-axi` again via mise's global config, so `tasks-axi` is reachable from any directory.
  Never runs as root at container runtime.
- `docker-compose.yml` (root) - `dev` service (the toolchain/test container) and `web` service (see "The web placeholder" below).
- `.dockerignore` - excludes `config/`, `host/`, `data/`, `state/`, `projects/`, `.no-mistakes/`, and `.made/evidence/` from the build context, so none of that gitignored, boss-private content is ever baked into an image layer, regardless of what happens to exist on disk when the image is built.
  Tracked `.made/features/` stays in the context; do not exclude `.made/` as a whole.
- `scripts/ci/run-in-container.sh` - builds the `dev` image and runs a given command inside it.
  Adapted from niceuptime's own `scripts/ci/run-in-dev-container.sh` wrapper pattern.

## Local usage

- `mise run dev:install` - build the `dev` and `web` images.
- `mise run dev:up` - bring up the local dev stack.
- `mise run dev:shell` - open an interactive shell inside the `dev` container.
- `mise run dev:test` - run consigliere's existing portable test suite (`bin/cs-test-run.sh --portable`, unmodified) inside the `dev` container.
- `mise run dev:down` - tear down the local dev stack.

## Mount-masking: why the sensitive paths can never leak

`config/`, `host/`, `data/`, `state/`, `projects/`, leftover `.no-mistakes/`, and `.made/evidence/` are this repo's gitignored, boss-private operational state (`docs/configuration.md` owns the complete layout).
Tracked `.made/features/` is review material and must stay visible inside the container.
Two independent protections keep the private paths out of the dev-tools suite entirely:

1. `.dockerignore` excludes those private paths from the Docker build context, so `docker/dev/Dockerfile`'s `COPY . /workspace` step can never bake their real content into any image layer, no matter what exists in the directory the image is built from.
2. `docker-compose.yml`'s `dev` service mounts the repo root read-write, then mounts an anonymous (empty, ephemeral) volume over each private path inside the container - a standard Compose masking technique.
   Even if a bind-mounted host directory has real content, the container's view of those paths stays empty.
   The overlay is `.made/evidence/`, never `.made/`, so the tracked features index remains visible.

The `web` service needs neither protection: it mounts only `./web:/srv/web:ro`, nothing else.

## The web placeholder

Consigliere itself has no web frontend today.
The boss asked for the container to be generically web-capable anyway, in case that changes later, so `web/index.html` is a fixed, minimal placeholder page, served by the `web` Compose service on port 8080 (`python3 -m http.server`).
It is not real product content - just a reserved, testable slot.

## CI

`.github/workflows/ci.yml`'s `lint`, `test-coverage`, and `portable` jobs stay on `ubuntu-latest`, but `portable` and `test-coverage` now run their `bin/cs-test-run.sh` invocation through `scripts/ci/run-in-container.sh`, inside the same `dev` image the local workflow above uses.
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
