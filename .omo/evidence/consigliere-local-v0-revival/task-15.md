# Task 15 evidence

## Scope and canary input

Task #15 is the plan's issue #140, the operator-controlled FirstMate canary.

The operator-selected Mission was to remove only the public Zumba repository entry from the main-host `bootstrap.repos` table in `mise.main.toml`.

The selected source was a clean `dotfiles` clone at its `main` tip, with base SHA `ed12af8b7e630d47a0384d42362b2fa53ab932d7`.

No Project was preselected by the product, no paired duplicate work was started, and no fixed duration or Continue limit was used.

The FirstMate configuration inputs were read from `/Users/douglasjarquin/github/douglasjarquin/dotfiles/files/firstmate/agent/config/crew-dispatch.json`, `/Users/douglasjarquin/github/douglasjarquin/dotfiles/files/firstmate/main/config/crew-dispatch.json`, and `/Users/douglasjarquin/github/douglasjarquin/dotfiles/files/firstmate/runner/config/crew-dispatch.json`.

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

Comparable Mission count remains below the required minimum of 20 completed, naturally occurring records.

The canary evidence is insufficient for Promote and makes no economic or superiority claim.

The human operator explicitly chose Continue by authorizing a same-task retry after the earlier no-result Attempt.

That Continue decision does not authorize a fixed duration, a fixed Continue limit, duplicate comparison work, or an automatic Promote decision.

## Same-task recovery measurement

The fresh packaged Consigliere measurement used the committed revival head `ed3f4d0e51b41b585a0141910b4d374d063891d4`.

The private canary `CS_HOME` was a temporary operator-owned home and its raw database, usage rows, manifests, and logs remain outside this repository.

The first bridge-enabled Attempt was `0ac0db2d-f568-4db4-862c-d9028a23628c`.

It imported checkpoint SHA `2c5579a09572c4008560c18dde7c194f9920335a` from the trusted base `ed12af8b7e630d47a0384d42362b2fa53ab932d7`.

The operator then continued the same Mission from that exact checkpoint, creating exactly one fresh recovery Attempt `ec118f71-3e8d-43a0-b7fb-064d74f0a708` with a new Workspace generation and fence.

The recovery Attempt imported the same exact checkpoint SHA and remained checkpointed rather than falsely becoming completed.

Both Attempt manifests ended in `dead_verified` with exit code 0, and the daemon-owned result record for each Attempt was `checkpoint` and `imported`.

The second Attempt emitted a completion report after its checkpoint report.

The durable first-terminal rule preserved the checkpoint result and rejected the later completion as `result_conflict`, preventing a false review-ready projection.

The temporary canary daemon stopped through packaged `csd stop` with exit code 0, removed its PID file, and left no matching daemon, runner, or Codex process.

The bounded private usage ledger recorded one row per Attempt.

The first row recorded sequence 57 with input 463311, cached input 425728, and output 8165 tokens.

The recovery row recorded sequence 43 with input 437784, cached input 406272, and output 5567 tokens.

The recorded ContextPack measurements were 3087 bytes and 772 input tokens for the first Attempt, and 3234 bytes and 809 input tokens for the recovery Attempt.

The measurement used `codex-cli 0.151.0`, harness `codex`, model `gpt-5.6-luna`, reasoning effort `high`, `workspace-write` sandbox, and `never` approval policy.

The packaged artifact hashes were `cs` `3c8ea2d7d27acf44d7a3df79b277885f77e635793cc49f0d2c7d29122ba2e9df`, `csd` `2e3687d3efa580bb15c2423f8d3e6b69f4b5c674f987a2efc902c141b9d0d3cf`, `cs-runner` `eb3895ce22035205b6c06ea2e4e197e9e4a0645b7a04bd3eb05cfd398f7f2358`, and `cs-attempt` `2e489d90e01196587a4665cf6ab1280939b8187b9bc86a0e668815d96e9493e4`.

The FirstMate inputs remained the three operator-provided optimized configuration files, with agent SHA-256 `f3f1d3152b9fa47584cb35c03096346221d1160713608be516ee855113c9e33c` and main and runner SHA-256 `a23edfca5017c9823ee3fae08601d39c96958edd591d050a383b5acaa89a0675`.

No FirstMate Mission was forced and no duplicate implementation was created because the operator supplied one natural task and no comparable Mission sample across both systems.

The recovery run therefore records one human Continue decision, two recoverable Consigliere Attempt records, zero completed comparable Missions, and insufficient evidence for Promote.

## Final packaged same-task retry

After the status-surface fix, the operator-selected same task was run once from a fresh private `CS_HOME` with a fresh auth-only Codex home and the package built from `31379603d124b7f0f4452a3525a500ad12b5e9be`.

The final Project was `e6d27e58-6f87-45b0-93ec-3ed706cd8898` and the final Mission was `9fd5ddb4-508d-4d5b-a8c6-b4d8811f995f`.

The final Attempt was `4ce0ec04-409e-4c07-965d-50da22ccb03b`.

The final Attempt used a fresh Workspace identity and generation, authenticated runner fence, and fresh Codex invocation, all bound to the exact Project and Mission.

The Attempt completed with verified process-group death and imported exact result SHA `053257f093a6e6c7937e8c9fad49f272870cef6c`, whose parent was the trusted base `ed12af8b7e630d47a0384d42362b2fa53ab932d7`.

The result ref was `refs/consigliere/projects/e6d27e58-6f87-45b0-93ec-3ed706cd8898/attempts/4ce0ec04-409e-4c07-965d-50da22ccb03b/result`.

The Mission reached `ready_for_review` only after the literal review verification passed with input SHA `053257f093a6e6c7937e8c9fad49f272870cef6c` and output digest `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

The final Workspace was clean and its exact diff was one deletion of the requested public Zumba line from `mise.main.toml`, with no other tracked changes.

The private per-turn ledger recorded one bounded row with native sequence 23, input 288024, cached input 265472, and output 5461 tokens.

The ContextPack measured 3238 bytes and 810 estimated input tokens, and its persisted hash matched the private runtime record.

The final package hashes were `cs` `e97cd1f26134558fdc76db557f7ce57f0f172a97ad3c80fcaf692b5d1ee018f4`, `csd` `06c1ddcbcb1b2207f94d8b41224fa8652a101faab3cec81bb93508a8b34bf4c0`, `cs-runner` `99631840887bc4ebb034e2da9489dc88ead115455d571f8c8002c9485ac25543`, and `cs-attempt` `5d23cf4088ef1783de79e3e76ca6bc2b0d7933e1f884ebb4607cc52e5d4df1d3`.

The final packaged manual path ran `csd restart`, `cs status MISSION`, `cs why MISSION`, `cs review`, `cs doctor`, `csd status`, and `csd stop`.

The restart acquired a new daemon identity, the status and explanation surfaces exposed the exact result and passed verification, doctor reported live sockets and verified lock ownership, and stop removed the PID file after cleanup.

The final run is one completed Consigliere record and zero FirstMate records, so there is no defensible cross-system comparable sample and no Promote claim.

## Adversarial coverage

- Malformed command input was exercised by the rejected Codex flag and was contained as a bounded spawn failure.
- Unsupported model configuration was exercised by the rejected `gpt-5` request and was contained as an authenticated Codex failure.
- A dirty-worktree scenario was not injected into the selected Mission because doing so would change the operator's requested work rather than test its execution path.
- A hung-command scenario occurred naturally during the Codex validation search and was reconciled as a verified-dead lost Attempt.
- Cancel and native resume were not used because V0 forbids native transcript resume and the selected Mission had no operator cancellation decision.
- Repeated interruption was not forced because it would create duplicate or non-natural canary work.
- Misleading model output was not trusted; final Workspace identity and exact Git diff checks were used instead.
- The private reporter's unsupported `progress` subcommand was rejected with bounded usage errors, while the supported checkpoint path remained authenticated and durable.
- Fresh packaged Codex startup emitted bounded warnings for optional agent definition files absent from the isolated `CODEX_HOME`; the native Codex task continued and no credentials or transcripts were exposed.
- Python `tomllib` was unavailable in the isolated environment, so the Mission used the installed `mise` parser path and recorded the parser warning without treating it as a successful model claim.
- A duplicate checkpoint-plus-completion report was contained by the first-terminal result rule and surfaced as a durable `result_conflict` rather than overwriting the checkpoint.
- A long worktree-relative `CS_HOME` reproduced the macOS Unix-domain socket `einval` boundary; the final measurement used a short private home and recorded the failed owner cleanup as an identity-safe refusal rather than unlinking by path.
- One local polling wrapper used zsh's reserved `status` variable and interrupted its own run; packaged `csd stop` then reconciled the exact runner group, and the final retry used a task-specific state variable.
- A host Codex configuration with unrelated plugin activity was isolated from the final run by supplying only a temporary auth file through `CS_CODEX_AUTH_HOME`; the auth copy was moved to Trash after the run.
- The final completion's exact result, verification digest, status projection, restart identity, and stop cleanup were independently checked after the original advisory conversation was absent.
- Prompt injection was not observed in the selected repository content, and the bounded Mission context restricted authority to the listed Attempt operations.
- Network delivery, GitHub mutation, pull request creation, push, and merge were not attempted by the canary.

No credentials, raw Codex configuration, full prompt, transcript, or unredacted logs are included here.

## Final exact-head package retry boundary

After the selected canary record, exact head `8d839378a55e36222e13c19e84e1f91543fc92c4` was packaged and exercised through the installed `csd migrate`, `csd start`, `cs ping`, `cs doctor`, `csd stop`, `csd restart`, and repeated-stop lifecycle.

The package was native macOS arm64 and the installed lifecycle ended with zero sockets, PID files, owner files, notification files, and package processes.

The current package and cleanup receipts are `.omo/evidence/consigliere-local-v0-revival/package-artifact-8d83937.log` and `.omo/evidence/consigliere-local-v0-revival/installed-lifecycle-8d83937.log`.

The selected canary was not rerun because doing so would create duplicate implementation work; its one Mission, two operator-authorized Attempts, zero FirstMate records, and insufficient Promote evidence remain authoritative.

## Record accounting

This evidence record intentionally preserves the earlier package qualification and failure-probe records instead of collapsing their Mission and Attempt identifiers.

The initial package starts failed before a completed comparable Mission because of the removed Codex flag, unsupported model, or lost protocol completion.

The recovery measurement recorded checkpoint-only Attempts and no completed comparable Mission.

Mission `9fd5ddb4-508d-4d5b-a8c6-b4d8811f995f` is disclosed as a pre-final-package qualification run that reached `ready_for_review` for the same operator-selected task, but it is excluded from the selected final canary aggregate and was not paired with a FirstMate run.

The selected final canary record is Mission `aac827b7-a6dd-490a-afbd-99aa79dd1859` below, using the committed-head package and one checkpoint Attempt followed by one operator-authorized continuation Attempt.

Only that selected final record is summarized as the public canary result, and no FirstMate Mission was created for either Consigliere qualification run.

After the fencing-test race fix, the operator-selected same task was rerun from a fresh private `/tmp` home with the package built from committed head `e2b7fe445e96c356354f31f849e9756b265ecec8`.

The package artifact hashes were `cs` `2c77e2b0ed1f87a78d38c966d702ac17c7c9bd8ee9053f813642c50bb0c601d3`, `csd` `919e3f9bf7e096ec6935c9515f8946db3c40e748d520de30a802943a742ab5c6`, `cs-runner` `a111504562104299ba4feda9bf2e52eb4f6937c8283c09798d8a5d04ead366b3`, and `cs-attempt` `1aef556b30e2e6fe65f56deb05b224afdcdd117bfb582d9f0cc5c4cd6837a379`.

The packaged `cs version --json` response was `{"cs":"0.1.0","protocol":1}` and all four artifacts were native macOS arm64 Mach-O executables.

The selected Project was `c3921ef4-41f8-4e13-9206-a6f325d977c9`, the Mission was `aac827b7-a6dd-490a-afbd-99aa79dd1859`, and the trusted base SHA was `ed12af8b7e630d47a0384d42362b2fa53ab932d7`.

The first Attempt was `077036c7-ef27-4ef2-9b56-27ca28918e50`.

It committed and imported checkpoint SHA `861c2932c6f3a868560913b630bafddcceb8e8d8`, ended with a `dead_verified` manifest, and left the Mission active with an explicit recoverable checkpoint.

The operator then authorized one continuation from that exact checkpoint.

The continuation Attempt was `5d3af514-de9c-4679-963a-2707b4714d43` with parent checkpoint SHA `861c2932c6f3a868560913b630bafddcceb8e8d8`.

It imported the same exact result SHA, ended with a `dead_verified` manifest, and moved the Mission to `ready_for_review` only after the literal review verification passed.

The verification input SHA was `861c2932c6f3a868560913b630bafddcceb8e8d8`, the output digest was `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, and the bounded output size was zero bytes.

The private usage ledger recorded one bounded row per Attempt.

The first row recorded sequence 13 with input 131730, cached input 118784, and output 2227 tokens, with a 3083-byte ContextPack and 771 estimated input tokens.

The continuation row recorded sequence 13 with input 263670, cached input 238080, and output 2669 tokens, with a 3230-byte ContextPack and 808 estimated input tokens.

Both rows recorded `codex-cli 0.151.0`, harness `codex`, model `gpt-5.6-luna`, reasoning effort `high`, `workspace-write` sandbox, and `never` approval.

The post-run packaged manual path executed `csd restart`, `cs status`, `cs why`, `cs review`, `cs doctor`, `csd status`, and `csd stop`.

The status, why, and review surfaces exposed the exact imported SHA and passed verification, doctor reported live sockets and verified lock ownership before stop, and stop removed the PID file.

The workspace commit was `861c2932c6f3a868560913b630bafddcceb8e8d8` with parent `ed12af8b7e630d47a0384d42362b2fa53ab932d7` and exactly one deletion from `mise.main.toml`.

The two Attempt manifests were `dead_verified`, all recorded runner and harness PIDs were absent, and the API, privileged, boss, and PID paths were absent after stop.

This committed-head retry is the selected final canary record with one completed Consigliere Mission and zero FirstMate Missions.

The natural comparable sample remains below 20, so the evidence is insufficient for Promote and makes no economic superiority claim.

No duplicate implementation, push, pull request, merge, fixed allocation, hard duration, fixed Continue limit, or telemetry service was introduced.

## Post-canary runtime and package closure

The final runtime head after the audit fixes is `42933d103da9171c76b1564888e0d6557291fb5d`.

The exact selected Mission was not rerun after these fixes because the operator-controlled canary forbids duplicate implementation work.

The final package was built from that runtime head at `.tmp/package-42933d1.mZakYT`.

Its native arm64 artifact hashes were `cs` `4b3891c4a27c3c21b10c8324627f2701288cdf83842f8a02619da61df2dd4a2c`, `csd` `400d29f584f7ceacf225608cb28c25ddaf3c9846b19e8e8aa890496afa020b48`, `cs-runner` `fa583582034b6c3aa1c1831f387fe578519172990876c6cf4774c28b7b12a382`, and `cs-attempt` `9393d8fecbadaf680caec85f260443fed17c9a5bdaa76a3ad408d683d95b2acb`.

The installed-only lifecycle ran from `/tmp` with `env -i`, passed migration, start, ping, health, doctor, status, repeated stop, restart, and final stop, and left zero package processes, sockets, PID files, owner files, and notification logs.

The cleanup receipt was `CLEANUP=trashed:/tmp/cs-final-42933d1-home.e7matc`; the isolated environment home `/tmp/cs-final-42933d1-env.C2tGuR` was also moved to Trash.

## Final runtime-hardening package custody

The final runtime source head is `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

Its package artifact and installed lifecycle passed in `package-artifact-7c54c78.md` and `installed-lifecycle-7c54c78.md`.

The package-only lifecycle verified version `0.1.0`, protocol `1`, live health and ping, identity-safe stop, restart with a new verified owner, repeated-stop idempotence, and zero final sockets, PID files, owner files, or package processes.

The final runtime hardening was exercised through full daemon, CLI, runner, package, and lifecycle gates.

The completed real canary was not rerun against this package because doing so would create duplicate implementation work for the same operator-selected Mission.

The canary remains one naturally occurring Consigliere Mission with one human-authorized continuation, zero FirstMate duplicate Missions, and fewer than 20 comparable natural Mission records.

The public result therefore remains insufficient for Promote, and Continue or Stop remains an operator decision.

The CI-shaped Linux daemon gate used actual Go `1.26.6` and passed format, warnings-as-errors compilation, and `482 tests` including one doctest in each of three consecutive seed-0 runs.

The CLI and runner Go gates passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The final result remains insufficient for Promote because only one naturally occurring Consigliere Mission and zero FirstMate Missions are available, and the operator retains the next Continue or Stop decision.

## Final exact-head package closure

The final implementation head is `bf22b5d4cae239a222a3065ca4b34b574dd676ad`.

The selected canary Mission and its two Attempts were not rerun after the runtime hardening because the operator-controlled canary forbids duplicate implementation work.

The package rebuilt from the final head passed the installed-only lifecycle from `/tmp`, including migration, start, ping, health, doctor, status, repeated stop, restart, and final stop with zero residual package processes.

The exact package identities, command results, and Trash cleanup receipt are recorded in `package-artifact-bf22b5d.log` and `installed-lifecycle-bf22b5d.log`.

The final result remains insufficient for Promote because only one naturally occurring Consigliere Mission and zero FirstMate Missions are available, and the operator retains the next Continue or Stop decision.
