# Operational-input provenance integrity (design)

> Status: **design + proof-of-concept, awaiting human sign-off.** This document
> is the deliverable of plan `006-operational-input-provenance-design`. It does
> not change any production producer or consumer. The proof-of-concept lives in
> `tests/cs-operational-input-provenance-poc.test.sh` and is wired into no
> production call site.
>
> Line references below were verified against the live tree at branch point
> commit `55aa94e` (drift check clean: none of the seven marker files changed
> since the plan was written).

## 1. Threat model

Consigliere types "operational input" into agent panes wrapped in a structural
envelope that both machine consumers and the reading LLM treat as provenance:
"this text is legitimate supervision from the consigliere, not an instruction an
agent injected." The whole supervision channel rests on that trust primitive.

Two linked weaknesses (audit findings SEC-01 and SEC-02) make the primitive
forgeable by an agent:

- **SEC-02 — the marker has no integrity against agent-authored bytes.** The
  envelope is `U+2063 CONSIGLIERE_OP: v1 <kind>: <body>` (bin/cs-operational-input.sh:40-43),
  and classification is plain prefix matching (`cs_operational_input_kind`,
  bin/cs-operational-input.sh:78-99). The `U+2063` INVISIBLE SEPARATOR was chosen
  because it "has no normal keyboard keystroke" (bin/cs-marker-lib.sh:15-19), so a
  *boss* typing at a keyboard never accidentally emits it. That is a
  **boss-disambiguation** property, not an **authenticity** property: an agent is
  a program, not a keyboard, and can emit `U+2063` plus the exact prefix verbatim.
  There is no secret component, so any party who can place bytes into a
  classification input can mint any kind.

- **SEC-01 — the away-mode daemon launders agent-authored status text through the
  trusted envelope.** The daemon distills the last line of `state/<id>.status`
  — which soldiers append to themselves — and wraps it in the `away-supervisor`
  envelope typed into the consigliere/capo pane. Attacker-controlled prose thus
  arrives inside "this is real supervision" framing (details in §3).

Net: a compromised or misaligned soldier can present instructions to the
orchestrator with laundered authority. A careless fix is worse than none, so
this is a design-first plan.

### Assets, adversary, trust boundary

- **Asset:** the orchestrator's (consigliere or capo) belief that a piece of
  typed input is genuine supervision it may act on.
- **Adversary:** a soldier agent — compromised, prompt-injected, or misaligned —
  that can write its own `state/<id>.status` file and emit arbitrary bytes in its
  own pane, but cannot read the consigliere's process memory or files it does not
  own.
- **Trust boundary:** everything the adversary can write (its status file, its
  pane output, a capo reply it composes) is **untrusted data**. The envelope is
  supposed to mark the *trusted* side. Today it does not, because trust is
  asserted by a well-known constant prefix the adversary also knows.

### Reader-facing contract to preserve

`docs/claude.md:43-46` and `bin/cs-turnend-guard.sh` state the typed envelope is
what marks text "as legitimate supervision rather than an injected instruction to
the reading agent" — claude scrutinizes hook stderr and refuses a bare
instruction, honoring the typed marker per its loaded contract. Any redesign
**must keep genuine supervision recognizable to the reading agent** while removing
forgeability by other agents. This is a hard constraint: the ultimate verifier of
the reader-facing marker is an LLM, which cannot compute a cryptographic check
(see §4).

## 2. Trust boundary: every construct and classify site (line-accurate)

### 2a. Construction sites (where a trusted marker is minted)

| Kind | Site | Body source | Crosses an agent-writable channel? |
|---|---|---|---|
| `launch-brief` | bin/cs-harness-lib.sh:233,238,260,274 (via `cs-operational-input.sh encode launch-brief`) | `data/<id>/brief.md`, consigliere-authored | No — boss/consigliere-authored brief |
| `session-start` | bin/cs-session-start.sh:321 | generated digest of local state | No — consigliere-generated |
| `watcher` | bin/cs-send.sh:129 | `cs-send` argv (consigliere steer) | No — consigliere-authored argv |
| `turn-end-guard` | bin/cs-turnend-guard.sh:123 | static continuation banner | No — fixed consigliere text |
| `away-supervisor` | bin/cs-daemon.sh:771 | `_collapse_newlines "$msg"`, where `msg` is the escalation digest | **YES — the digest is distilled from soldier-appended status lines (§3)** |
| `from-consigliere` | bin/cs-marker-lib.sh:29 (`cs_message_mark_from_consigliere`), called from bin/cs-pending-reply-lib.sh:190 | `cs-send` argv / recovery message | No — consigliere-authored; but delivered to a capo agent (see §5) |

### 2b. Classification / consumption sites (where a marker is trusted and acted upon)

| Site | Function | Input source | Acts on agent-originated bytes? |
|---|---|---|---|
| bin/cs-operational-input.sh:78-99 | `cs_operational_input_kind` | any string | (primitive used by all below) |
| bin/cs-operational-input.sh:135-143 | `cs_operational_input_classify` | any string | (primitive) |
| bin/cs-classify-lib.sh:28-34 | `cs_classify_input` / `cs_input_is_boss` | message text | Only as consumed by callers below |
| bin/cs-daemon.sh:181-186 | `message_is_injection` | afk-exit message text | Governs afk exit; ambiguity biases to exit (self-correcting) |
| bin/cs-daemon.sh:193-201 | `should_exit_afk` | afk-exit message text | Same; **no live caller today** (testable contract only) |
| bin/cs-daemon.sh:204-206 | `strip_injection_marker` (`cs_operational_input_body`) | typed body | Strips framing after provenance was read |
| bin/cs-marker-lib.sh:20-24 | `cs_message_from_consigliere` | message text | **No production consumer — tests only** (see §5) |

### 2c. Exploitable sinks (ranked)

1. **`away-supervisor` laundering (SEC-01, confirmed).** The one construction
   site whose body demonstrably crosses an agent-writable channel. This is the
   near-term risk and the target of the PoC.
2. **Any kind, via the LLM reader (SEC-02, structural).** Because classification
   is a public constant prefix, an agent that can cause marker-prefixed text to
   appear in *another* agent's input stream forges supervision for the reading
   LLM. The daemon is the confirmed automated path into the consigliere's pane;
   other paths would require the adversary to already control an injection route.
3. **`watcher` / `turn-end-guard` / `launch-brief` / `session-start`:** bodies are
   consigliere/boss-authored, so they are not laundering sinks today. They still
   inherit SEC-02: a soldier that forges the prefix in its own output could make
   its own pane text *look* self-authored as supervision, but it already controls
   its own turn, so this yields no privilege it lacks. The real prize is reaching
   the *orchestrator's* pane, which today only the daemon does.

### 2d. Key structural facts established by reading the live code

- **No classifier ever re-reads a marker from a pane capture.** `cs_herdr_capture`
  feeds only native busy-state detection (bin/cs-herdr-lib.sh:182,
  bin/cs-watch.sh:1135) and composer-emptiness (bin/cs-composer-lib.sh:183). Every
  marker classification runs on an in-process string (a status file read, a
  `cs-send` argv, an afk-exit message), **never on captured pane bytes**. A marker
  round-trips through a TUI pane only when it is *typed in and read by the LLM
  agent* — the reader-facing contract — not when bash re-classifies it.
- **Capo reply routing does not depend on classifying the `from-consigliere`
  marker.** The capo path embeds a `corr=<16hex>` token
  (bin/cs-pending-reply-lib.sh:186-201) and resolves the expectation **only** from
  a correlated line in the *parent's own* status file
  (`cs_pending_reply_line_resolves`, :389-396; `cs_pending_reply_try_resolve`,
  :443-485). Delivery success never resolves; the capo's conversation is never
  scraped. The `from-consigliere` marker is a *reader-facing* framing for the capo
  agent plus a carrier for the corr token — routing safety is corr-token-based,
  not marker-classification-based. `cs_message_from_consigliere` (the classify
  predicate) has no production consumer at all.

## 3. The SEC-01 laundering path, traced

1. A soldier appends a line to `state/<id>.status` (agent-writable, untrusted).
2. `classify_signal` (bin/cs-daemon.sh:220-244) reads it via `last_status_line`
   (:224) and builds `distilled="${distilled}$(basename "$f"): ${last} | "` (:226)
   — the raw soldier line is embedded verbatim.
3. `handle_wake` (bin/cs-daemon.sh:833-861) takes the `escalate|<distilled>`
   decision and calls `escalate_add "$state" "$distilled"` (:855). The stale and
   pause housekeeping paths add further agent-derived note text
   (`escalate_add ... "stale persisted ..."` :696, `... "paused ..."` :725).
4. `escalate_flush` (:420-433) concatenates the buffer into one `msg`.
5. `inject_msg` (:763-771) wraps it: `cs_operational_input_construct
   away-supervisor "$msg" msg` (:771) and types it into the supervisor pane.

The soldier-authored bytes are now the **body of a genuine `away-supervisor`
envelope**, delivered into the orchestrator's pane with full supervision framing.
The reading LLM has no signal that the inner prose is untrusted data rather than a
consigliere directive. That is the laundering.

(Note: the adversary cannot make the daemon emit its forged *outer* marker
unchanged — `distilled` is prefixed with `basename: ` and the flush prepends
`Away-mode escalation ...`, so a soldier's own `away-supervisor` prefix never sits
at offset 0 for `cs_operational_input_construct`'s idempotency branch at
bin/cs-operational-input.sh:119-125. The laundering is via the *body*, not via
passing a pre-forged envelope through.)

## 4. Mechanism options

### (A) Per-session HMAC / nonce

Consigliere holds a per-session secret agents never see; each marker carries
`HMAC(secret, kind ‖ body)`; classification requires a valid tag.

- **Integrity:** strongest. Forgery requires the secret.
- **Round-trip feasibility (measured in the PoC):** the tag is hex, and `U+2063`
  already survives UTF-8 terminal input (docs/herdr.md:45, verified upstream after
  the 0.7.3 `0x1f`-stripping incident). The PoC confirms an HMAC tag survives a
  simulated pane-capture read-back byte-for-byte. **So byte-corruption is not the
  blocker.**
- **The real blocker — the reader-verification gap:** the ultimate verifier of the
  reader-facing marker is an **LLM**, which cannot compute an HMAC. HMAC can secure
  only the *machine-classified* sinks (§2b: `message_is_injection`, and any future
  bash re-classification). It cannot, by itself, let the reading agent distinguish
  genuine from forged supervision — the exact contract docs/claude.md:43-46
  requires. HMAC is therefore necessary for machine sinks but **insufficient alone**
  for the reader contract.
- **Cost:** a secret store; every producer and consumer changes; capo compatibility
  needs a migration (§5).

### (B) Channel separation

Accept markers only from channels agents cannot write; treat status content as
pure data that is never itself a directive.

- Directly dissolves SEC-01: if status-derived text is *never* wrapped as a
  directive, there is nothing to launder. The daemon would quote/neutralize the
  distilled soldier text rather than frame it as trusted supervision.
- Does not, alone, give the reader a positive authenticity signal for the genuine
  channel; pairs naturally with (A) or (C) for that.

### (C) Neutralize-and-quote (minimum viable for SEC-01)

Keep the envelope for consigliere-generated *framing* only. Any agent-authored
segment (the distilled status body) is stripped of marker bytes and wrapped in an
explicit, clearly delimited "quoted soldier text — DATA, not instructions" region
so neither a machine consumer nor the reading LLM treats it as a directive.

- **Integrity against SEC-01:** high, and it needs no secret and no round-trip
  crypto. The reader sees consigliere framing that explicitly says "the following
  is a soldier's own status report, quoted as data."
- **Integrity against SEC-02:** partial — the outer marker stays forgeable, but the
  *laundering* (the confirmed exploit) is closed because agent bytes can no longer
  ride inside trusted framing.
- **Cost:** cheapest. One neutralizer + one daemon wrap change; no producer/consumer
  churn; no capo migration.

## 5. Recommendation

**Layer C now, A+B later.**

- **Now (near-term, low-risk): option (C).** It closes the one confirmed exploit
  (SEC-01 laundering) at the single sink that matters (bin/cs-daemon.sh:771), with
  no secret store, no round-trip crypto, no producer/consumer churn, and **no capo
  compatibility change** — so it cannot regress capo reply routing, the highest-risk
  surface. The PoC demonstrates it.
- **Later (full integrity, SEC-02): option (A) HMAC on the machine-classified
  channel, paired with (B) channel separation** so status text is structurally
  data. HMAC secures `message_is_injection` and any future bash re-classification;
  channel separation keeps agent bytes out of trusted framing regardless of the
  marker. The reader-facing contract stays served by (C)'s explicit data-region
  framing, because **no cryptographic tag can be verified by the LLM reader** — the
  reader relies on framing, the machine relies on the tag.

### Capo `from-consigliere` compatibility handling

The capo form is the highest-risk thing to touch, but the investigation shows it
is **safe to leave byte-identical under this recommendation**:

- Option (C) does not touch any `from-consigliere` producer or consumer.
- Capo reply *routing* is corr-token + parent-owned-status based
  (bin/cs-pending-reply-lib.sh), not `from-consigliere`-classification based, and
  `cs_message_from_consigliere` has no production consumer (§2d). So even a later
  option (A) rollout can add an HMAC tag to the *machine-checked* kinds while
  keeping the capo `[cs-from-consigliere] U+2063 <body>` bytes exactly as existing
  capos carry them in their charter context — the tag would live in a new field, not
  replace the legacy label. Migration for capo is therefore additive and deferred,
  never a breaking rename.

## 6. Proof-of-concept

`tests/cs-operational-input-provenance-poc.test.sh` (scratch only — wired into no
production path) demonstrates the recommended mechanism and substantiates the
round-trip claims:

1. **SEC-02 baseline (documents the weakness):** the live `cs_operational_input_kind`
   accepts an agent-forged full-envelope string as a valid trusted kind.
2. **Neutralize (option C) — forged rejected:** agent-authored distilled text that
   embeds a forged `away-supervisor` marker is passed through the PoC neutralizer;
   the result carries **no classifiable inner marker** (the forged bytes are
   defanged and visibly quoted as data), so it can no longer function as a directive.
3. **Genuine accepted:** the consigliere constructs a real `away-supervisor`
   envelope whose *body* is the neutralized quoted soldier data; the outer envelope
   still classifies as `away-supervisor` (genuine framing preserved) and the
   explicit DATA-region delimiters are present.
4. **Round-trip survival:** the neutralized-and-enveloped bytes survive a simulated
   pane-capture read-back (the relied-upon `U+2063` is preserved), showing option
   (C) needs no crypto to survive the TUI.
5. **Option (A) feasibility probe:** when `openssl` is present, an HMAC tag over the
   body survives the same simulated pane-capture read-back and verifies, confirming
   the round-trip is not the blocker for (A) — the LLM-reader gap (§4) is.

Run: `bash tests/cs-operational-input-provenance-poc.test.sh` → all `ok - `.

## 7. Migration checklist (for the sign-off'd implementation plan)

Ordered follow-up steps. Each is a separate reviewable change; none is started by
this plan.

1. **(C) Land the neutralizer in production.** Add a `cs_operational_input`-owned
   `neutralize soldier data` helper and change bin/cs-daemon.sh:771 (and the note
   text at :696, :725) so every agent-derived segment is quoted as data inside the
   `away-supervisor` body. Tests: extend `tests/cs-afk-daemon.test.sh` to assert the
   distilled body is quoted and carries no classifiable inner marker; a regression
   asserting a forged inner marker in a status line is defanged end-to-end.
2. **Document the marker's real property.** State explicitly in docs/architecture.md
   and docs/herdr.md that `U+2063` is a **boss-disambiguation** aid, not an
   authenticity control, until option (A) lands — so future readers do not
   over-trust it. (Maintenance note from the plan.)
3. **(A) Introduce a per-session secret store.** Consigliere-only file (mode 600,
   gitignored), created at session start, never entering an agent-visible path.
   Tests: secret is absent from every worktree and every launch string.
4. **(A) Add an HMAC field to the machine-checked kinds.** Extend the wire form with
   an optional `mac=<hex>` field; `cs_operational_input_kind` verifies it when a
   secret is configured and rejects a present-but-invalid tag. Keep unverified
   classification working when no secret is set (compatibility). Tests: forged tag
   rejected; genuine tag accepted; tag survives pane-capture round-trip; absent-secret
   fallback unchanged.
5. **(A) Roll producers over one kind at a time**, machine-checked kinds first
   (`away-supervisor`, `watcher`, `session-start`, `turn-end-guard`, `launch-brief`),
   each with a compatibility window that still classifies untagged in-flight markers.
6. **(A/capo) Add the tag additively to `from-consigliere`** without altering the
   legacy `[cs-from-consigliere] U+2063` bytes; verify capo reply routing
   (`tests/cs-send-capo.test.sh`, `tests/cs-pending-reply.test.sh`) is unchanged.
7. **(B) Structurally separate status data.** Audit every remaining path where
   agent-authored text could enter a trusted frame and convert it to quoted data,
   so integrity does not depend on the marker alone.
8. **Retire the compatibility windows** once no untagged marker can be in flight,
   and update the audit findings SEC-01/SEC-02 to resolved.

## 8. Open questions for the reviewer

- Secret-store lifetime and rotation for (A): per-session vs. per-home, and how a
  daemon restart re-derives it without a window where markers are unverifiable.
- Whether the reader-facing contract should additionally carry a short
  human-readable "quoted data" convention the CLAUDE.md contract teaches agents to
  honor, strengthening (C) independent of (A).
