#!/usr/bin/env bash
# bin/cs-composer-lib.sh - composer-emptiness classifier backing the composer
# guard every guarded-prompt caller shares (bin/cs-prompt-lib.sh). Sourced,
# never executed. Requires bin/cs-herdr-lib.sh to be sourced first
# (cs_herdr_capture).
#
# HARNESSES: recognizes both agent prompt glyphs - codex `›` and claude `❯`
# (distinct codepoints, so recognition is universal, no harness plumbing). codex
# fills an empty composer with a dim ghost suggestion (stripped below); claude's
# empty composer (verified 2.1.218, 2026-07-24) is a bare `❯` between horizontal
# rules with NO ghost text, so the ghost strip is a no-op there and harmless.
#
# WHY: a guarded-prompt caller (bin/cs-activate.sh, via bin/cs-prompt-lib.sh)
# injects into consigliere's own pane, so it must know the agent composer is
# AFFIRMATIVELY empty first. Typing into a half-typed boss line merges two
# messages; typing into a dead shell could EXECUTE the injected text. Only
# 'empty' authorizes injection; 'pending' and 'unknown' both defer (the
# buffered delivery survives for the next tick).
#
# GHOST TEXT (ported upstream incident, 2026-07-08, recorded in docs/codex.md):
# codex fills an otherwise-empty composer with a de-emphasized inline
# suggestion after the bare `›` prompt. A plain capture cannot tell that ghost
# apart from text a human typed, so a naive reader classifies the idle pane as
# 'pending' forever and the caller wedges overnight. cs_composer_strip_ghost is
# the ANSI-aware extractor of REAL typed content: it drops dim/faint runs
# (SGR 2, how codex styles its ghost suggestion) and dark/muted TRUECOLOR
# foreground runs (luminance below CS_COMPOSER_GHOST_LUMA_MAX on a dark theme),
# keeping only normal-intensity, normally-coloured text.
#
# DOCUMENTED FAILURE DIRECTION: if the transport strips ANSI styling (so ghost
# text arrives as plain bytes), ghost becomes indistinguishable from typed
# input and classifies 'pending'. That fails toward DEFER, never toward a
# wrong injection; a persistent defer is surfaced by the caller's own max-defer
# wedge alarm instead of wedging silently.
#
# PIPELINE: capture with ANSI -> locate the composer row structurally on
# ANSI-stripped rows -> extract real typed content from the raw styled row ->
# normalize Unicode spaces and trim (_cs_composer_trim, which every trim here
# goes through) -> classify. Normalization exists because bash's [[:space:]]
# class is locale-dependent: under LC_ALL=C it does not match U+00A0, so an
# NBSP-padded empty composer row never trims to empty and classifies 'pending'
# forever, deferring injection until the max-defer wedge alarm fires.
# _cs_composer_normalize_spaces matches raw UTF-8 bytes instead, so the verdict
# is identical under a UTF-8 locale and LC_ALL=C. It only lets a GENUINELY
# empty row read empty: an NBSP that separates real typed content still leaves
# that content behind, so the row stays 'pending'.
#
# SAFETY RULE for prompt glyphs (one owner). A GLYPH NEVER PROVES AN AGENT.
# Claude's `❯` (U+276F) is also the prompt character of common shell themes
# (pure, starship, p10k), so the glyph sets are NOT disjoint: a pane whose agent
# exited to a login shell draws the very same `❯`, and reading it as an empty
# agent composer is what would let a guarded-prompt caller type into a dead
# shell and EXECUTE it (reproduced from real bytes, docs/claude.md).
#
# What proves a composer is the SHAPE THE HARNESS DRAWS, per harness:
#   bordered box (`│ … │`)  - the harness drawing its own prompt; a shell cannot
#                             draw it, so a shell glyph inside one is 'empty'.
#   claude, bare `❯`        - claude draws its composer BETWEEN horizontal rule
#                             rows (`───`, verified 2.1.227), so only a `❯` row
#                             with a rule immediately above it is PROVEN to be a
#                             composer.
#   codex, bare `›`         - codex draws no box; the bare row is the composer.
#   bare shell glyph (`>`, `$`, `%`, `#`) - never a composer shape at all.
# The proof gates 'empty' ONLY. An unproven `❯` row still classifies its content
# normally, so a row carrying leftover text stays 'pending' and the callers that
# act on that (bin/cs-control-lib.sh's pre-exit flush) keep working; it is the
# EMPTY verdict - the one that authorizes typing - that degrades to 'unknown'.
# That also settles the nastiest layout: a stale composer still in scrollback
# above a live shell prompt. The shell prompt is the LAST match, it is unproven,
# and it is empty, so the capture reads 'unknown' instead of inheriting the dead
# composer's verdict.
# On top of the shape, an 'empty' verdict from a BARE row is corroborated
# against the pane's process table: an agent process must actually be running
# there (cs_herdr_pane_agent_process). That covers what the shape alone cannot -
# a prompt theme that draws its own rule above the prompt. Unreadable process
# info therefore costs availability, never correctness: it defers.
# Both checks fail toward DEFER: anything not positively proven to be an empty
# AGENT composer is 'unknown'. 'empty' is never widened.

# Lines of pane bottom scanned for the composer row.
CS_COMPOSER_LINES=${CS_COMPOSER_LINES:-20}

# cs_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row detection, where ghost text must be KEPT so the box
# border or prompt glyph stays visible; content extraction uses
# cs_composer_strip_ghost instead. stdin -> stdout. The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) strips whole.
cs_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# cs_composer_strip_ghost: extract real typed content from one raw styled
# composer row (stdin from an ANSI capture; stdout plain non-ghost text).
# Drops dim/faint runs (SGR 2; reset by SGR 0/22) and dark-TRUECOLOR
# foreground runs (38;2;r;g;b or 38:2::r:g:b with luminance below
# CS_COMPOSER_GHOST_LUMA_MAX, default 128; reset by SGR 0/39/base colours).
# 256-colour foregrounds (38;5;n) are kept: palette-dependent, not used for
# codex ghost text, and under-stripping only defers (the safe direction).
# LC_ALL=C walks bytes so multibyte glyphs (›) pass through intact.
cs_composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${CS_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0 }
                else if (code == "22") dim = 0
                else if (code == "39") darkfg = 0
                else if (code + 0 >= 30 && code + 0 <= 37) darkfg = 0
                else if (code + 0 >= 90 && code + 0 <= 97) darkfg = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 && darkfg == 0) out = out c   # keep non-de-emphasised bytes
        i++
      }
      print out
    }
  '
}

# _cs_composer_normalize_spaces: rewrite Unicode space separators to a plain
# ASCII space so the trim below sees them. Bash's [[:space:]] class is
# locale-dependent and does NOT match U+00A0 under LC_ALL=C, so an NBSP-padded
# empty composer row would otherwise never trim to empty. The substitutions
# match RAW UTF-8 BYTE sequences, verified identical under a UTF-8 locale and
# LC_ALL=C: U+00A0, U+2000..U+200A, U+202F, U+205F, U+3000.
_cs_composer_normalize_spaces() {  # <text>
  local s=$1
  s=${s//$'\xc2\xa0'/ }                     # U+00A0 no-break space
  s=${s//$'\xe2\x80'[$'\x80'-$'\x8a']/ }    # U+2000..U+200A en/em/thin/etc spaces
  s=${s//$'\xe2\x80\xaf'/ }                 # U+202F narrow no-break space
  s=${s//$'\xe2\x81\x9f'/ }                 # U+205F medium mathematical space
  s=${s//$'\xe3\x80\x80'/ }                 # U+3000 ideographic space
  printf '%s' "$s"
}

# _cs_composer_is_rule: is this trimmed, ANSI-stripped row one of the horizontal
# rules claude draws above and below its composer? True only when the row is
# NOTHING but rule characters and carries a run of at least three, so a line of
# prose that happens to contain one `─` is not mistaken for the composer's
# frame. Matches raw UTF-8 bytes (U+2500, U+2501) for the same locale
# independence _cs_composer_normalize_spaces needs.
_cs_composer_is_rule() {  # <trimmed-row>
  local s=$1
  case "$s" in
    *$'\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'*|*$'\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81'*) ;;
    *) return 1 ;;
  esac
  s=${s//$'\xe2\x94\x80'/}
  s=${s//$'\xe2\x94\x81'/}
  [ -z "$s" ]
}

# _cs_composer_trim: normalize Unicode spaces, then strip leading and trailing
# whitespace. Every trim in this file goes through here, so normalization
# happens once, before any structural match or emptiness verdict.
_cs_composer_trim() {  # <text>
  local s
  s=$(_cs_composer_normalize_spaces "$1")
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# cs_composer_classify_content: the empty|pending|unknown verdict for one
# ghost-stripped, border-stripped, trimmed composer content string.
#   <bordered> 1 when the content came from a genuine bordered composer box;
#              0 for a bare `›` codex prompt row.
cs_composer_classify_content() {  # <bordered> <content>
  local bordered=$1 content=$2
  case "$content" in
    '›'|'❯')
      printf 'empty'; return 0 ;;          # agent glyph (codex ›, claude ❯): empty either way
    '>'|'$'|'%'|'#')
      # Shell glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Strip one leading prompt glyph, then re-judge the remainder.
  case "$content" in
    '› '*|'❯ '*|'> '*|'$ '*|'% '*|'# '*) content=${content#??} ;;
    '›'*|'❯'*|'>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
  esac
  content=$(_cs_composer_trim "$content")
  [ -n "$content" ] || { printf 'empty'; return 0; }
  printf 'pending'; return 0               # real, unsubmitted content remains
}

# cs_composer_state: classify pane <pane_id>'s agent composer as
# empty|pending|unknown (always prints one token, exits 0). Captures the pane
# bottom WITH ANSI styling (cs_herdr_capture ... ansi), locates the composer
# structurally on the ANSI-stripped rows - keeping the LAST match so a
# decorative box earlier in the window never outranks the live bottom composer:
#   bordered - trimmed row both starts and ends with a border glyph (│ ┃ |)
#   bare     - trimmed row starts with codex's `›`, or with claude's `❯` when
#              the previous non-blank row is one of claude's composer rules
# A `❯` row WITHOUT that rule is most likely a login shell's prompt (the glyph
# sets are not disjoint - see the safety rule above), so it still matches but is
# UNPROVEN, which forbids only the 'empty' verdict. A bare shell glyph is not a
# composer shape at all. Real typed content is then extracted from the RAW
# styled row with cs_composer_strip_ghost and handed to
# cs_composer_classify_content, and an
# 'empty' verdict off a bare row must still be corroborated by an agent process
# actually running in the pane. No composer row found, an unreadable pane, and
# an uncorroborated bare row are all 'unknown' (defer).
cs_composer_state() {  # <pane_id>
  local pane=$1 cap line trimmed found=0 bordered=0 raw_match="" stripped
  local prev_rule=0 proven=0 verdict
  cap=$(cs_herdr_capture "$pane" "$CS_COMPOSER_LINES" ansi 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed=$(printf '%s' "$line" | cs_composer_strip_ansi)
    trimmed=$(_cs_composer_trim "$trimmed")
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        bordered=1; raw_match=$line; found=1; proven=1 ;;
      '›'*)
        bordered=0; raw_match=$line; found=1; proven=1 ;;
      '❯'*)
        bordered=0; raw_match=$line; found=1; proven=$prev_rule ;;
    esac
    if _cs_composer_is_rule "$trimmed"; then prev_rule=1; else prev_rule=0; fi
  done <<EOF
$cap
EOF
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=$(printf '%s\n' "$raw_match" | cs_composer_strip_ghost)
  stripped=$(_cs_composer_trim "$stripped")
  if [ "$bordered" = 1 ]; then
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped=$(_cs_composer_trim "$stripped")
  fi
  verdict=$(cs_composer_classify_content "$bordered" "$stripped")
  if [ "$verdict" = empty ]; then
    [ "$proven" = 1 ] || verdict=unknown
  fi
  if [ "$verdict" = empty ] && [ "$bordered" != 1 ] \
    && ! cs_herdr_pane_agent_process "$pane" >/dev/null 2>&1; then
    verdict=unknown
  fi
  # BLOCKED-AGENT GATE (ported upstream fix, firstmate #2811): an agent parked
  # on an interactive dialog - a permission prompt, a trust dialog, a question
  # menu - reports native agent_status=blocked (docs/codex.md "Directory trust
  # blocks an unattended launch") while the dialog is drawn OUTSIDE the composer
  # region, so structure alone can still look like a free composer. Typing there
  # would answer the dialog - selecting its highlighted default and discarding
  # the text - which is exactly the pane where typing is unsafe. Structure
  # cannot disprove that, so a blocked agent forces the empty verdict down to
  # 'unknown' (defer) here, in the ONE owner of the empty verdict, covering
  # every consumer. Only native `blocked` demotes: an unreadable status is
  # 'unknown', not blocked, so the existing structural proof still governs and
  # availability is unchanged when `agent get` cannot answer.
  if [ "$verdict" = empty ] \
    && [ "$(cs_herdr_agent_status_raw "$pane")" = blocked ]; then
    verdict=unknown
  fi
  printf '%s' "$verdict"
}
