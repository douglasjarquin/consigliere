# Dev-tools suite: mise + aube + container for Mac, CI, and Cursor Cloud Agents

This is a purely additive dev-tools suite on top of consigliere's own bash-script tooling.
No existing `bin/*.sh` script's content changed to add it.
It exists to give consigliere its own reproducible, container-based environment - `mise` for tooling/tasks, `aube` for the JS package-manager work that needs it, and one Docker image consumed in three places: this Mac (`mise run dev:*` / `docker-compose.yml`), CI (`scripts/ci/run-in-container.sh`), and Cursor Cloud Agents (`.cursor/environment.json`).
Inspired by (not copied from) the boss's `niceuptime` project's own mid-implementation container setup.

## Layout

- `mise.toml` (root) - pins `node` and `aube` (`2.1`) for this suite's own project-scoped tooling.
  `tasks-axi` (`0.2.4`, matching `bin/cs-deps-lib.sh`'s `CS_TASKS_AXI_MIN` floor) is pinned separately, via mise's GLOBAL config inside the image (see below) - a project-scoped tool's shim only activates in a directory `mise.toml` governs, but tests invoke `tasks-axi` from scratch fixture directories with no `mise.toml` of their own.
  It does not replace `bin/cs-deps-lib.sh`, which stays the single owner of consigliere's own required/optional tool floors for the human/doctor-check path.
  The two are independent, compatible mechanisms: `mise.toml` governs what's baked into the container image; `cs-deps-lib.sh` governs what a human running consigliere directly needs on their own machine.
- `mise-tasks/dev/{install,up,down,shell,test}` - file-based mise tasks (namespaced `dev:*`), each a thin composition of already-built pieces (a mise task invoking a `docker compose` command), never a duplicate of logic that already lives in `bin/cs-test-run.sh` or `docker-compose.yml`.
- `docker/dev/Dockerfile` - a single image (deliberately not split into a toolchain image and a Cloud Agent or CI image the way niceuptime's own setup is - that split was flagged there as needing manual sync, a rough edge this image avoids).
  Installs the toolchain `bin/cs-test-run.sh --portable` needs (bash, git, jq, sqlite3, python3, gh, lsof, sudo), a pinned ShellCheck via `bin/cs-install-shellcheck.sh` (reused as-is, not modified), and a SHA-pinned `mise` bootstrap that then installs `node`/`aube` per `mise.toml` and `node`/`tasks-axi` again via mise's global config, so `tasks-axi` is reachable from any directory.
  Copies only those bake inputs (`mise.toml`, the ShellCheck installer, and `bin/cs-lint.sh` which owns the version pin).
  Cursor Cloud Agents check out the commit themselves, so the image must not `COPY` the full project.
  Never runs as root at container runtime.
  Default UID/GID 1000 (the Cloud Agent build) and compose-passed `DEV_UID`/`DEV_GID` (Mac/CI bind mounts) both keep working.
- `.cursor/environment.json` - Dockerfile-based Cloud Agent pointer at that same image, with repo-root build context and an idempotent `mise install` after clone.
  No `snapshot` field.
- `docker-compose.yml` (root) - `dev` service (the toolchain/test container) and `web` service (see "The web placeholder" below).
- `.dockerignore` - excludes `config/`, `host/`, `data/`, `state/`, `projects/`, `.no-mistakes/` from the build context, so none of that gitignored, boss-private content is ever baked into an image layer, regardless of what happens to exist on disk when the image is built.
- `scripts/ci/run-in-container.sh` - builds the `dev` image and runs a given command inside it.
  Adapted from niceuptime's own `scripts/ci/run-in-dev-container.sh` wrapper pattern.

## Local usage

- `mise run dev:install` - build the `dev` and `web` images.
- `mise run dev:up` - bring up the local dev stack.
- `mise run dev:shell` - open an interactive shell inside the `dev` container.
- `mise run dev:test` - run consigliere's existing portable test suite (`bin/cs-test-run.sh --portable`, unmodified) inside the `dev` container.
- `mise run dev:down` - tear down the local dev stack.

## Mount-masking: why the six sensitive paths can never leak

`config/`, `host/`, `data/`, `state/`, `projects/`, and `.no-mistakes/` are this repo's gitignored, boss-private operational state (`docs/configuration.md` owns the complete layout).
Two independent protections keep them out of the dev-tools suite entirely:

1. The Dockerfile copies only bake inputs, never the full tree, and `.dockerignore` still excludes all six from the Docker build context, so a later `COPY` cannot bake their real content into any image layer, no matter what exists in the directory the image is built from.
2. `docker-compose.yml`'s `dev` service mounts the repo root read-write, then mounts an anonymous (empty, ephemeral) volume over each of the six paths inside the container - a standard Compose masking technique.
   Even if a bind-mounted host directory has real content, the container's view of those six paths stays empty.

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

## Cursor Cloud Agents

`.cursor/environment.json` tells Cursor to build `docker/dev/Dockerfile` with repo-root context (`build.dockerfile` and `build.context` are relative to `.cursor/`) and to run `mise install` from the project root after clone.
That `install` script is idempotent checkout-dependent refresh, not a place for Docker, databases, or other long-running processes.
The runtime user is `cs`, with passwordless sudo.
When the default UID/GID 1000 build displaces the base image's `ubuntu` account, `ubuntu` is recreated as a same-UID alias so Cursor examples that assume that name still work; Mac and CI bind mounts keep keying off UID/GID.

Cloud Agents reset `PATH` at session start.
The image therefore links mise shims into `/usr/local/bin` and prepends the shims directory from `/etc/profile.d/cs-mise.sh` and `/home/cs/.bashrc`, rather than relying on `ENV PATH`.

Do not add a second Dockerfile or a `snapshot` field.
Private operational dirs stay out of the image: they are not bake inputs, `.dockerignore` excludes them from the build context, and compose still mount-masks them for local runs.

Portable coverage of this contract lives in `tests/cs-cursor-cloud-env.test.sh`.
The live Docker lane (`CS_TEST_DOCKER_LIVE=1`) still covers compose behavior and also builds the default UID/GID 1000 image, then checks git, sudo, mise, node, and tasks-axi on a distro-default PATH.

## Provenance

This suite is new work, inspired by (not copied from) the boss's `niceuptime` project's mid-implementation container setup, which itself is not part of this repo.
There is no ongoing sync between the two: this suite evolves independently once it lands.
