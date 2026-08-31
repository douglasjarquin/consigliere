# Review finding 5 - verification command containment

Head before this correction: 0c6b3552b03b5d0a24d65c7fb5885295a7ce563a.

RED: the new process-level regressions showed stderr was absent from the result and a timed-out shell child survived (`kill -0` returned status 0).

GREEN: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/project_verifications_command_test.exs --no-color` returned `Result: 8 passed`.

The command now uses the packaged `cs_setsid` helper, combines stderr, computes one deadline from command start, caps each received chunk before materialization, and terminates the owned process group on timeout or output overflow.

The one QA child left by the RED probe was explicitly terminated by PID and its temporary workspace was removed by the test teardown.
