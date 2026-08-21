#!/bin/sh
# Protocol-faithful stand-in for `made validate --managed`.
# Honors --decisions and CS_FAKE_MADE_OUTCOME. Always exits.
set -eu
run_id=""
invocation_id=""
mission_id=""
gate_id=""
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
    --invocation-id) invocation_id="$2"; shift 2 ;;
    --mission-id) mission_id="$2"; shift 2 ;;
    --gate-id) gate_id="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --input-sha) input_sha="$2"; shift 2 ;;
    --base-sha) base_sha="$2"; shift 2 ;;
    --policy-hash) policy_hash="$2"; shift 2 ;;
    --decisions) decisions="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$invocation_id" ]; then
  invocation_id="$run_id"
fi

if [ -z "$gate_id" ]; then
  gate_id="$run_id"
fi

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

common="\"schema_version\":\"1\",\"protocol_version\":\"consigliere.made.managed.v1\",\"run_id\":\"$run_id\",\"invocation_id\":\"$invocation_id\",\"mission_id\":\"$mission_id\",\"gate_id\":\"$gate_id\",\"base_sha\":\"$base_sha\",\"input_sha\":\"$input_sha\",\"policy_hash\":\"$policy_hash\""

seq=1
printf '%s\n' "{\"event\":\"stage.started\",${common},\"sequence\":${seq}}"

emit_terminal() {
  seq=$((seq + 1))
  printf '%s\n' "{\"event\":\"run.completed\",${common},\"sequence\":${seq},\"outcome\":\"$1\"}"
}

case "$outcome" in
  passed)
    emit_terminal "passed"
    exit 0
    ;;
  needs_decision)
    seq=$((seq + 1))
    printf '%s\n' "{\"event\":\"stage.finding\",${common},\"sequence\":${seq},\"finding\":{\"finding_code\":\"REVIEW\",\"finding_class\":\"correctness\",\"path\":\"lib/x.ex\",\"symbol\":\"run\",\"description\":\"needs a decision\",\"severity\":\"blocking\",\"fingerprint\":\"$fingerprint\"}}"
    seq=$((seq + 1))
    printf '%s\n' "{\"event\":\"run.needs_decision\",${common},\"sequence\":${seq},\"findings\":[{\"finding_code\":\"REVIEW\",\"fingerprint\":\"$fingerprint\"}],\"decision_request\":{\"question\":\"waive $fingerprint?\",\"options\":[\"waive\",\"block\"]}}"
    emit_terminal "needs_decision"
    exit 2
    ;;
  failed_retryable)
    emit_terminal "failed_retryable"
    exit 3
    ;;
  failed_terminal)
    emit_terminal "failed_terminal"
    exit 4
    ;;
  infrastructure_error)
    emit_terminal "infrastructure_error"
    exit 5
    ;;
  canceled)
    emit_terminal "canceled"
    exit 6
    ;;
  *)
    emit_terminal "infrastructure_error"
    exit 5
    ;;
esac
