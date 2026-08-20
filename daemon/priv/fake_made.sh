#!/bin/sh
# Protocol-faithful stand-in for `made validate --managed`.
# Honors --decisions and CS_FAKE_MADE_OUTCOME. Always exits.
set -eu
run_id=""
workspace="."
input_sha=""
base_sha=""
policy_hash=""
decisions=""
fingerprint="${CS_FAKE_MADE_FINGERPRINT:-fp-default}"
outcome="${CS_FAKE_MADE_OUTCOME:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    validate|--managed|--json-events) shift ;;
    --run-id) run_id="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --input-sha) input_sha="$2"; shift 2 ;;
    --base-sha) base_sha="$2"; shift 2 ;;
    --policy-hash) policy_hash="$2"; shift 2 ;;
    --decisions) decisions="$2"; shift 2 ;;
    *) shift ;;
  esac
done

waived=0
if [ -n "$decisions" ] && [ -f "$decisions" ]; then
  if grep -q "$fingerprint" "$decisions" 2>/dev/null; then
    if grep -q "sha_bound" "$decisions" 2>/dev/null; then
      if grep -q "$input_sha" "$decisions" 2>/dev/null; then
        waived=1
      fi
    else
      waived=1
    fi
  fi
fi

if [ "$waived" -eq 1 ]; then
  outcome="passed"
fi

if [ -z "$outcome" ]; then
  outcome="needs_decision"
fi

printf '%s\n' "{\"event\":\"stage.started\",\"run_id\":\"$run_id\",\"stage\":\"review\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"

case "$outcome" in
  passed)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"passed\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 0
    ;;
  needs_decision)
    printf '%s\n' "{\"event\":\"stage.finding\",\"run_id\":\"$run_id\",\"stage\":\"review\",\"finding\":{\"finding_code\":\"REVIEW\",\"finding_class\":\"correctness\",\"path\":\"lib/x.ex\",\"symbol\":\"run\",\"description\":\"needs a decision\",\"severity\":\"blocking\",\"fingerprint\":\"$fingerprint\"}}"
    printf '%s\n' "{\"event\":\"run.needs_decision\",\"run_id\":\"$run_id\",\"stage\":\"review\",\"findings\":[{\"finding_code\":\"REVIEW\",\"fingerprint\":\"$fingerprint\"}],\"decision_request\":{\"question\":\"waive $fingerprint?\",\"options\":[\"waive\",\"block\"]}}"
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"needs_decision\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 2
    ;;
  failed_retryable)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"failed_retryable\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 3
    ;;
  failed_terminal)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"failed_terminal\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 4
    ;;
  infrastructure_error)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"infrastructure_error\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 5
    ;;
  canceled)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"canceled\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 6
    ;;
  *)
    printf '%s\n' "{\"event\":\"run.terminal\",\"run_id\":\"$run_id\",\"outcome\":\"infrastructure_error\",\"input_sha\":\"$input_sha\",\"base_sha\":\"$base_sha\",\"policy_hash\":\"$policy_hash\"}"
    exit 5
    ;;
esac
