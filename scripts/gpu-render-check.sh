#!/usr/bin/env bash
# gpu-render-check.sh — tell the consumer WHICH renderer its browser eyes actually got.
#
#   bash scripts/gpu-render-check.sh            # cheap preconditions — SILENT when all present
#   bash scripts/gpu-render-check.sh --render   # authoritative: launch Chrome, print the real renderer
#   bash scripts/gpu-render-check.sh --json     # machine-readable (implies the cheap mode)
#
# WHY THIS EXISTS (2026-07-29). The shipped chrome-devtools MCP config forces the ANGLE GL backend
# and carries --enable-unsafe-swiftshader, so it uses the GPU where there is one and silently falls
# back to software where there is not. That fallback is the right behaviour — the page still renders
# — but it is SILENT, and the gap it hides is large: measured on this box, one 3D page cost 9.1 cores
# in software and 0.6 cores on a discrete NVIDIA GPU. A 15x slowdown with no signal gets attributed to "the
# tool is slow" instead of "the GPU is not wired up", which is a debugging trap, not a performance
# one. So: keep the fallback silent to the PAGE, and make it loud to the OPERATOR.
#
# THE TWO MODES ARE NOT THE SAME CLAIM, and the labels say so:
#   * cheap mode reads PRECONDITIONS (driver, GL vendor library, the MCP flags). It can prove a
#     negative — "this will be software" — but it must never claim the positive, because the only
#     thing that knows which renderer Chrome chose is Chrome. It says "looks right, run --render".
#   * --render is the real answer: it launches Chrome with the SHIPPED flags and reads
#     UNMASKED_RENDERER_WEBGL out of a live WebGL context. It costs ~2s.
#
# Exit: 0 = hardware confirmed (--render) or preconditions present (cheap) · 3 = software fallback
#       in effect · 2 = could not determine. Software is a legitimate state, not a crash — 3 is a
#       heads-up, not a failure, so a caller that only cares about breakage can ignore it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MODE=check
JSON=0
for a in "$@"; do
  case "$a" in
    --render) MODE=render ;;
    --json)   JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "gpu-render-check: unknown option: $a" >&2; exit 2 ;;
  esac
done

# ── the MCP config the agent's eyes are actually launched from ────────────────────────────────
# Checked because a config edit is the one failure the hardware checks below cannot see: a box with
# a perfect GPU still renders in software if the flags were dropped, and vice versa the ANGLE flag
# without its fallback partner leaves a GPU-less machine with NO WebGL at all.
mcp_flags() {
  # Resolve the config that is actually LIVE for the caller — which is a different file for this
  # repo than for an adopter, verified 2026-07-29 rather than assumed:
  #   * kickoff-dev enables only the telegram plugin, so its chrome-devtools comes from the repo's
  #     own project-scope .mcp.json — the file this repo edits.
  #   * an adopted repo typically has NO .mcp.json of its own and enables the kickoff plugin, so
  #     its chrome-devtools comes from the PLUGIN CACHE at
  #     ~/.claude/plugins/cache/<marketplace>/kickoff/<version>/.mcp.json. Checked against every
  #     adopted checkout available at the time; none carried a project-scope config.
  # Reading the engine's plugin/.mcp.json would report the shipped INTENT while the cache serves the
  # running reality — and those genuinely differ: every cached version through 0.3.14 carries no GPU
  # flags, so an adopter stays on software until a pull lands 0.3.16 and refreshes the cache.
  # Order is live-first, intent last.
  local d="$PWD" f=""
  while :; do
    [ -r "$d/.mcp.json" ] && { f="$d/.mcp.json"; break; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  if [ -z "$f" ]; then
    # newest cached kickoff plugin — sort -V so 0.3.9 never outranks 0.3.16
    f="$(ls -d "$HOME"/.claude/plugins/cache/*/kickoff/*/.mcp.json 2>/dev/null \
          | sed 's|/\.mcp\.json$||' | sort -t/ -k9 -V | tail -1)/.mcp.json"
    [ -r "$f" ] || f="$REPO/plugin/.mcp.json"
  fi
  [ -r "$f" ] || f="$REPO/.mcp.json"
  [ -r "$f" ] || return 1
  MCP_CONFIG_PATH="$f"
  python3 - "$f" <<'PY' 2>/dev/null
import json,sys
try:
    a=json.load(open(sys.argv[1]))['mcpServers']['chrome-devtools']['args']
except Exception:
    sys.exit(1)
print(' '.join(a))
PY
}

FLAGS="$(mcp_flags || true)"
has_angle=0; has_fallback=0
case "$FLAGS" in *use-angle*)               has_angle=1 ;; esac
case "$FLAGS" in *enable-unsafe-swiftshader*) has_fallback=1 ;; esac

# ── hardware preconditions ───────────────────────────────────────────────────────────────────
GPU_NAME=""
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
fi
GL_LIB=0
if ldconfig -p 2>/dev/null | grep -q libEGL_nvidia; then GL_LIB=1; fi

# ── --render: the only mode that can claim the positive ──────────────────────────────────────
if [ "$MODE" = render ]; then
  CH="$(find "$HOME/.cache/puppeteer/chrome" -name chrome -type f 2>/dev/null | sort | tail -1)"
  if [ -z "$CH" ]; then
    for c in /usr/bin/google-chrome /usr/bin/chromium-browser /snap/bin/chromium; do
      [ -x "$c" ] && CH="$c" && break
    done
  fi
  if [ -z "$CH" ]; then
    echo "gpu-render-check: no Chrome binary found — cannot render. (checked ~/.cache/puppeteer/chrome and the system paths)" >&2
    exit 2
  fi
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/gl.html" <<'HTML'
<html><body><div id=o>pending</div><script>
try{ var c=document.createElement('canvas'), gl=c.getContext('webgl2')||c.getContext('webgl');
     var d=gl.getExtension('WEBGL_debug_renderer_info');
     document.getElementById('o').textContent='RENDERER='+gl.getParameter(d.UNMASKED_RENDERER_WEBGL);
}catch(e){ document.getElementById('o').textContent='RENDERER=NONE:'+e.message; }
</script></body></html>
HTML
  # Drive it with the SHIPPED flags — testing a different flagset would answer a question nobody
  # asked. Falls back to the known-good triple only if the config could not be read.
  CARGS=""
  if [ -n "$FLAGS" ]; then
    for w in $FLAGS; do case "$w" in --chrome-arg=*) CARGS="$CARGS ${w#--chrome-arg=}" ;; esac; done
  fi
  [ -n "${CARGS// /}" ] || CARGS="--use-gl=angle --use-angle=gl-egl --enable-unsafe-swiftshader"
  # NO --user-data-dir, deliberately. A fresh profile makes Chrome do first-run initialisation,
  # which on this kind of headless box blocks on GCM registration and retries for 80+ seconds — the
  # DOM never gets dumped and the check times out looking like a launch failure. Measured 2026-07-29:
  # with an explicit --user-data-dir (fresh OR persistent) stdout was 0 bytes; without it, instant.
  # --no-first-run and --disable-background-networking do NOT rescue it. The already-initialised
  # default profile is free here because the MCP's own browsers run with --isolated temp profiles.
  R="$(timeout 60 "$CH" --headless=true --no-sandbox $CARGS \
        --dump-dom "file://$TMP/gl.html" 2>/dev/null | grep -o 'RENDERER=[^<]*' | head -1)"
  R="${R#RENDERER=}"
  if [ -z "$R" ]; then
    echo "gpu-render-check: Chrome produced no renderer string (launch failed or timed out)" >&2
    exit 2
  fi
  case "$R" in
    NONE:*)
      printf '❌ WebGL is UNAVAILABLE in the configured browser (%s)\n' "${R#NONE:}"
      printf '   The ANGLE backend is forced without a software fallback — on this machine that\n'
      printf '   leaves no renderer at all. Add --chrome-arg=--enable-unsafe-swiftshader.\n'
      exit 2 ;;
    *SwiftShader*|*swiftshader*)
      printf '⚠ browser eyes are on the CPU (software rendering)\n'
      printf '   renderer: %s\n' "$R"
      printf '   Rendering still WORKS, it is just ~15x more expensive (measured: 9.1 cores vs 0.6\n'
      printf '   on one 3D page). Visual passes will be slow; that is the cause, not the tool.\n'
      [ "$GL_LIB" = 0 ] && printf '   Cause here: no libEGL_nvidia on the library path (scripts/enable-gpu-gl.sh installs it).\n'
      [ "$has_angle" = 0 ] && printf '   Cause here: .mcp.json does not pass --chrome-arg=--use-angle=gl-egl.\n'
      exit 3 ;;
    *)
      printf '✅ browser eyes are on the GPU\n   renderer: %s\n' "$R"
      exit 0 ;;
  esac
fi

# ── cheap mode: silent when nothing is wrong, and never claims the positive ───────────────────
problems=0
warn() { printf '⚠ %s\n' "$1"; problems=$((problems+1)); }

[ "$has_angle" = 1 ] || warn ".mcp.json does not pass --chrome-arg=--use-angle=gl-egl — browser eyes will render on the CPU."
if [ "$has_angle" = 1 ] && [ "$has_fallback" = 0 ]; then
  warn ".mcp.json forces ANGLE WITHOUT --enable-unsafe-swiftshader — on a machine with no GPU that leaves NO WebGL at all, not slow WebGL."
fi
[ -n "$GPU_NAME" ] || warn "no GPU visible to nvidia-smi — browser eyes will render on the CPU (~15x slower; it works, it is just slow)."
if [ -n "$GPU_NAME" ] && [ "$GL_LIB" = 0 ]; then
  warn "GPU present ($GPU_NAME) but no libEGL_nvidia on the library path — Chrome cannot use it. scripts/enable-gpu-gl.sh installs the matching GL userspace libs."
fi

if [ "$JSON" = 1 ]; then
  printf '{"gpu":"%s","gl_vendor_lib":%s,"mcp_forces_angle":%s,"mcp_has_fallback":%s,"problems":%s}\n' \
    "${GPU_NAME:-}" "$GL_LIB" "$has_angle" "$has_fallback" "$problems"
fi

# Silence is the contract in cheap mode: nothing to say on a correctly-wired box, so this is safe to
# call from anywhere without adding noise. The positive claim is deliberately withheld — only Chrome
# knows what Chrome picked, so the most this mode ever says is "run --render".
[ "$problems" -eq 0 ] && exit 0
printf '   → confirm what the browser actually gets: bash scripts/gpu-render-check.sh --render\n'
exit 3
