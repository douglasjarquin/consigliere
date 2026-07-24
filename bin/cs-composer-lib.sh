#!/usr/bin/env bash
# bin/cs-composer-lib.sh - composer-emptiness classifier for the away-mode daemon
# (bin/cs-daemon.sh). Sourced, never executed. Requires bin/cs-herdr-lib.sh to be
# sourced first (cs_herdr_capture).
#
# HARNESSES: recognizes both agent prompt glyphs - codex `›` and claude `❯`
# (distinct codepoints, so recognition is universal, no harness plumbing). codex
# fills an empty composer with a dim ghost suggestion (stripped below); claude's
# empty composer (verified 2.1.218, 2026-07-24) is a bare `❯` between horizontal
# rules with NO ghost text, so the ghost strip is a no-op there and harmless.
#
# WHY: the daemon injects an escalation digest into consigliere's own pane, so
# it must know the codex composer is AFFIRMATIVELY empty first. Typing into a
# half-typed boss line merges two messages; typing into a dead shell could
# EXECUTE the digest. Only 'empty' authorizes injection; 'pending' and
# 'unknown' both defer (the buffered escalation survives for the next tick).
#
# GHOST TEXT (ported upstream incident, 2026-07-08, recorded in docs/codex.md):
# codex fills an otherwise-empty composer with a de-emphasized inline
# suggestion after the bare `›` prompt. A plain capture cannot tell that ghost
# apart from text a human typed, so a naive reader classifies the idle pane as
# 'pending' forever and the daemon wedges overnight. cs_composer_strip_ghost is
# the ANSI-aware extractor of REAL typed content: it drops dim/faint runs
# (SGR 2, how codex styles its ghost suggestion) and dark/muted TRUECOLOR
# foreground runs (luminance below CS_COMPOSER_GHOST_LUMA_MAX on a dark theme),
# keeping only normal-intensity, normally-coloured text.
#
# DOCUMENTED FAILURE DIRECTION: if the transport strips ANSI styling (so ghost
# text arrives as plain bytes), ghost becomes indistinguishable from typed
# input and classifies 'pending'. That fails toward DEFER, never toward a
# wrong injection; a persistent defer is surfaced by the daemon's max-defer
# wedge alarm (CS_MAX_DEFER_SECS) instead of wedging silently.
#
# SAFETY RULE for prompt glyphs (one owner, ported from upstream
# fm-composer-lib): an agent glyph (codex `›`, claude `❯`) is a genuine empty
# agent composer, bordered or bare. A bare SHELL glyph (`>`, `$`, `%`, `#`) is what a
# pane shows once its agent exited to a login shell; it is 'empty' ONLY inside
# a real bordered composer box (the harness drawing its own prompt) and never
# on an unstructured row - structurally, a bare shell-glyph row is not even
# recognized as a composer here, so it stays 'unknown'.

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

_cs_composer_trim() {  # <text>
  local s=$1
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
#   bare     - trimmed row starts with an agent glyph (codex `›`, claude `❯`; a
#              bare shell glyph is deliberately NOT a composer shape: unknown)
# then extracts real typed content from the RAW styled row with
# cs_composer_strip_ghost and hands the verdict to
# cs_composer_classify_content. No composer row found, or an unreadable pane,
# is 'unknown' (defer).
cs_composer_state() {  # <pane_id>
  local pane=$1 cap line trimmed found=0 bordered=0 raw_match="" stripped
  cap=$(cs_herdr_capture "$pane" "$CS_COMPOSER_LINES" ansi 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed=$(printf '%s' "$line" | cs_composer_strip_ansi)
    trimmed=$(_cs_composer_trim "$trimmed")
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        bordered=1; raw_match=$line; found=1 ;;
      '›'*|'❯'*)
        bordered=0; raw_match=$line; found=1 ;;
    esac
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
  cs_composer_classify_content "$bordered" "$stripped"
}
