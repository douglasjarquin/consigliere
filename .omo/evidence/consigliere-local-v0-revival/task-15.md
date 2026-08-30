# Task 15 evidence

## Scope and canary input

Task #15 is the plan's issue #140, the operator-controlled FirstMate canary.

The operator-selected Mission was to remove only the public Zumba repository entry from the main-host `bootstrap.repos` table in `mise.main.toml`.

The selected source was a clean `dotfiles` clone at its `main` tip, with base SHA `ed12af8b7e630d47a0384d42362b2fa53ab932d7`.

No Project was preselected by the product, no paired duplicate work was started, and no fixed duration or Continue limit was used.

The FirstMate configuration inputs were read from the three operator-provided paths.

All three resolved to harness `codex`, model `gpt-5.6-luna`, and reasoning effort `high`.

The agent configuration SHA-256 was `f3f1d3152b9fa47584cb35c03096346221d1160713608be516ee855113c9e33c`.

The main and runner configuration SHA-256 was `a23edfca5017c9823ee3fae08601d39c96958edd591d050a383b5acaa89a0675`.

The Consigliere package used the native macOS arm64 `cs`, `csd`, `cs-runner`, and OTP release produced by `scripts/package.sh`.

The packaged daemon used `codex-cli 0.151.0`, harness `codex`, model `gpt-5.6-luna`, reasoning effort `high`, sandbox `workspace-write`, and approval policy `never`.

The package probe reported native `Mach-O 64-bit executable arm64` artifacts for `cs`, `csd`, and the OTP `erlexec`.

## Tests-first and packaged findings

The first packaged launch was a RED process proof because the package reused a Linux OTP release tree and `erlexec` reported an ELF binary on macOS.

The package script now removes the generated production release tree before rebuilding, which prevents cross-platform OTP artifacts from being copied into the installed package.

The relative-prefix package path was separately reproduced RED because the script exited successfully while placing the Go clients under the `cli` directory.

The package script now canonicalizes the prefix before changing build directories.

The relative-prefix package rerun was GREEN and produced native `cs`, `csd`, and `erlexec` binaries.

The Codex argv characterization was changed RED-first after the real CLI rejected the removed `--ask-for-approval` flag.

The adapter now uses the installed CLI's `-c approval_policy=never` form.

The supported `gpt-5.6-luna` default was characterized RED-first after the live ChatGPT account rejected `gpt-5` with HTTP 400.

The native Codex adapter characterization passed 14 tests after those fixes.

The native dispatch characterization passed 3 tests after the test CS_HOME was shortened below the macOS Unix-domain socket path limit.

## Live packaged Mission results

The first live package attempt failed before Codex output because the installed CLI rejected `--ask-for-approval` with exit code 2.

The second live package attempt reached Codex and failed with the structured model-availability error for `gpt-5`.

The third live package attempt used the corrected argv and supported model.

That attempt authenticated the runner, created one isolated Workspace, and made the requested single-line deletion in `mise.main.toml`.

The Workspace remained at the exact trusted base SHA before the uncommitted edit and contained only the requested one-file, one-line change.

The target line was absent, the remaining `bootstrap.repos` rows were byte-for-byte equal to the base table after removing that line, and `git diff --check` passed.

The operator's installed `mise` was present at version `2026.8.14` for the final parser-validation lane.

The Attempt then lost its protocol completion while Codex was performing broad local TOML-tool discovery after the available Python lacked `tomllib`.

The runner and harness were verified dead, and the daemon reconciled the Attempt as `lost` with no checkpoint, result, usage record, or delivery SHA.

The uncommitted Workspace edit was not imported, committed, pushed, or delivered, so no durable project work was lost or duplicated.

This live run therefore supplies a real packaged failure exercise and a direct Workspace integrity proof, but it does not supply a completed comparable Mission record.

## Evidence sufficiency

Comparable Mission count is zero completed records out of the required minimum of 20.

The canary evidence is insufficient for Promote and makes no economic or superiority claim.

The report must remain open for the human operator's Continue or Stop decision.

No human Continue or Stop decision has been supplied in this run.

## Adversarial coverage

- Malformed command input was exercised by the rejected Codex flag and was contained as a bounded spawn failure.
- Unsupported model configuration was exercised by the rejected `gpt-5` request and was contained as an authenticated Codex failure.
- A dirty-worktree scenario was not injected into the selected Mission because doing so would change the operator's requested work rather than test its execution path.
- A hung-command scenario occurred naturally during the Codex validation search and was reconciled as a verified-dead lost Attempt.
- Cancel and native resume were not used because V0 forbids native transcript resume and the selected Mission had no operator cancellation decision.
- Repeated interruption was not forced because it would create duplicate or non-natural canary work.
- Misleading model output was not trusted; final Workspace identity and exact Git diff checks were used instead.
- Prompt injection was not observed in the selected repository content, and the bounded Mission context restricted authority to the listed Attempt operations.
- Network delivery, GitHub mutation, pull request creation, push, and merge were not attempted by the canary.

No credentials, raw Codex configuration, full prompt, transcript, or unredacted logs are included here.
