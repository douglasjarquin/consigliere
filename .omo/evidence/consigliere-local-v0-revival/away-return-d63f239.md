# Exact-head Away lock correction receipt

Runtime source head: `d63f2390944a534f4746c64ef60e43332fd546c3`.

The regression review identified that serializing all of `Away.return/1` changed the established bounded-overlap contract.

The corrected implementation constructs the return digest outside the shared home lock, then locks only cursor acknowledgement and token-checked marker removal.

`Away.mark/1` keeps its marker write and cursor upsert inside `:global.trans({{Consigliere.Away, Path.expand(home)}, self()}, fun)`.

The temporary `DatabaseWriter.serialize/2` API and test detour were removed.

Focused command: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/away_cursor_test.exs --no-color --seed N` for seeds `0` through `9`.

Result: every seed passed `7` tests, for `70` focused test executions and zero failures.

The overlapping-return assertions still accept stale returns and require the durable cursor to stop at the first bounded page.

The new concurrent mark regression holds the exact shared global resource in a separate task, proves both real `Away.mark/1` calls remain blocked, releases the holder, and verifies marker/cursor agreement.

Manual QA: the fresh installed package lifecycle passed migration, start, ping, doctor, stop, restart, post-restart ping, repeated stop, and final process cleanup.

Adversarial classes probed: overlapping returns, concurrent mark calls, stale marker token, oversized digest, malformed or stale state through the existing suite, and repeated interruption through the existing lifecycle gates.

No temporary production hook, sleep-based synchronization, or `DatabaseWriter` serialization detour remains in the corrected path.
