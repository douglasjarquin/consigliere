# Task 4 evidence: trusted Git bases and isolated workspaces

Plan item: #127, `Anchor Projects and workspaces to immutable trusted Git identities`.

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Commit: `feat(v0-03): bind workspaces to trusted Git bases`.

The required baseline suite initially passed with `23 passed`, but it did not cover Project audit events, base refresh, source-path canonicalization, or launch-time identity verification.

The RED characterization suite added those assertions and produced `5/9 passed` with four failures before implementation.

The RED output identified undefined `Projects.refresh_base/2` and `Projects.verify_workspace_identity/3`, a missing `project.registered` event, and a symlink source path being persisted without canonicalization.

Project registration now canonicalizes the local repository path with `realpath`, resolves the configured branch explicitly, imports its exact tip into a daemon-owned bare mirror, updates `refs/consigliere/projects/<project-id>/base`, and records a bounded `project.registered` event containing only branch, ref, and SHA identity.

Explicit base refresh imports and updates only the Project base and records `project.base_refreshed`.

Existing authorized Mission rows retain their original base SHA across Project refresh.

The Git boundary now uses daemon-controlled Git configuration for source inspection, mirror creation, workspace materialization, and workspace verification.

Workspace materialization fetches exact trusted refs, removes remotes, clears local credential helpers, points hooks to a daemon-owned empty hooks directory, rejects alternate object stores, and tightens repository permissions to owner-only modes.

Workspace and Git metadata symlink substitutions are rejected before trust verification.

The workspace destination is derived under the daemon-owned workspace root and mission-named path, and registered Projects reject arbitrary caller-provided workspace path shapes before durable start state is written.

Launch preparation verifies Project, Mission, workspace, lease, fencing generation, base SHA, parent checkpoint SHA, trusted mirror ref, exact workspace HEAD, remotes, hooks, credential helpers, permissions, and object-store independence immediately before the runner is started.

Incomplete fixture Projects remain usable by existing characterization tests, while a registered Project with a missing or changed identity fails closed before launch.

Targeted RED-to-GREEN proof:

```text
docker run --rm -v "$PWD/daemon:/workspace" -w /workspace elixir:1.20-otp-29 sh -lc 'mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/git_test.exs test/consigliere/projects_test.exs test/consigliere/projects_authorize_test.exs test/consigliere/workspaces/transitions_test.exs test/consigliere/workspaces/workspace_test.exs test/consigliere/missions/transitions_test.exs'
Result: 39 passed
```

The required named #127 suite itself passed with `26 passed` after the Git and Project implementation, and the mission transition characterization suite passed in the combined `39 passed` run.

The real manual QA used a temporary Git repository inside a disposable Linux container and a source symlink whose configured default branch was `main` while source `HEAD` was on `feature`.

The driver registered the Project, inspected the stored canonical source, mirror base ref, audit events, workspace object inodes, alternates, remotes, hooks path, credential helper configuration, and owner-only modes.

The driver renamed a worker loose object instead of deleting it and verified that the trusted mirror still contained the base commit.

The driver refreshed the Project base from a later `main` commit and verified the existing Mission still referenced the original base SHA.

```text
canonical_source=yes
configured_branch_tip=main
feature_tip_not_selected=yes
audit_event=project.registered,project.base_refreshed
workspace_objects_independent=yes
workspace_git_config_scrubbed=yes
workspace_modes_owner_only=yes
mirror_survived_worker_object_mutation=yes
refresh_preserved_mission_base=yes
task4_manual_qa=pass
```

The first manual-driver attempt was a fixture setup miss because the disposable test database had not been migrated and stopped before the product driver ran.

The second attempt corrected the database initialization but used the wrong mounted path for the temporary driver and stopped before product behavior.

The successful attempt used `MIX_ENV=test mix ecto.migrate` and the absolute mounted driver path.

The temporary driver and its disposable container were removed after the successful proof.

Adversarial coverage included feature-versus-default branch selection, symlink source identity, invalid branch and repository boundary behavior through the existing suite, remotes, hooks, credential helpers, alternates, unsafe permissions, path traversal shape, changed workspace base identity, worker-object mutation, Project refresh, and mirror preservation.

Prompt injection, cancel or resume semantics, hung Git commands, process liveness, runner termination, and repeated process interruption belong to later ordered runner and lifecycle tasks and were not claimed here.

No GitHub delivery state, source checkout `HEAD`, timestamps, `rev-list --all`, shared object store, caller-owned workspace root, or legacy supervisor was used as a trusted base.
