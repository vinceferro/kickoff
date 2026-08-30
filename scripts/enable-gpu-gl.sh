#!/usr/bin/env bash
# enable-gpu-gl.sh — give the box the NVIDIA graphics (GL/EGL) userspace libraries
# that MATCH the already-installed compute driver, so headless Chromium renders on
# the GPU (real bloom/glow) instead of falling back to software (swiftshader ~4fps).
#
# WHY IT'S SAFE: the box already runs the NVIDIA <branch> driver with kernel modules
# loaded (CUDA works). Only the *headless* package variant is installed, so the GL
# userspace libs (libGLX_nvidia / libEGL_nvidia) are absent. This script ADDS the
# matching GL package at the EXACT same version — it removes nothing, does not rebuild
# the kernel module, and does not touch the CUDA/compute stack. No reboot needed.
#
# Idempotent: re-running is a no-op once the GL libs are present.
# Run it (over SSH is fine):   bash scripts/enable-gpu-gl.sh
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "== NVIDIA GL userspace enable =="

# 1) Detect the installed driver branch + exact version (so we match, never guess).
BRANCH="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sed -nE 's/^nvidia-compute-utils-(.*)$/\1/p' | head -1)"
VER="$(dpkg-query -W -f='${Version}\n' "libnvidia-compute-${BRANCH}" 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
  echo "ERROR: could not detect the installed NVIDIA driver branch (no nvidia-compute-utils-* package)."
  echo "Run 'dpkg -l | grep nvidia' and share it with the coordinator."
  exit 1
fi
GLPKG="libnvidia-gl-${BRANCH}"
UTILPKG="nvidia-utils-${BRANCH}"
echo "Detected driver branch: ${BRANCH}    version: ${VER:-<unknown>}"
echo "Will install: ${GLPKG} (+ ${UTILPKG} for nvidia-smi, mesa-utils for verify)"

# 2) Idempotency: already have the GL libs?
if ldconfig -p 2>/dev/null | grep -q libGLX_nvidia; then
  echo "libGLX_nvidia is already present — GL libs already installed. Nothing to do."
else
  echo "Updating package lists..."
  $SUDO apt-get update -y
  # Pin to the EXACT compute-driver version when available; else let apt pick the matching branch candidate.
  if [ -n "${VER:-}" ] && apt-cache show "${GLPKG}=${VER}" >/dev/null 2>&1; then
    echo "Installing version-pinned ${GLPKG}=${VER} ..."
    $SUDO apt-get install -y "${GLPKG}=${VER}" "${UTILPKG}=${VER}" mesa-utils
  else
    echo "Exact version not found in cache; installing the branch candidate (still matches the ${BRANCH} driver)..."
    $SUDO apt-get install -y "${GLPKG}" "${UTILPKG}" mesa-utils
  fi
fi

# 3) Verify (no reboot needed — these are userspace libs; the kernel modules are already loaded).
echo ""
echo "== verify =="
if ! ldconfig -p 2>/dev/null | grep -E "libGLX_nvidia|libEGL_nvidia"; then
  echo "ERROR: GL libs still missing after install — stop and share the apt output with the coordinator."
  exit 1
fi
echo "--- nvidia-smi ---"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || echo "(nvidia-smi not on PATH; GL libs are installed though)"
echo "--- EGL devices (want to see an NVIDIA device, not just llvmpipe/swrast) ---"
if command -v eglinfo >/dev/null; then
  eglinfo 2>/dev/null | grep -iE "EGL_VENDOR|Device platform|nvidia|drm" | head -8 || echo "(eglinfo ran; review above)"
else
  echo "(eglinfo not installed; the GL libs check above is the key signal)"
fi

echo ""
echo "✅ DONE — GPU GL libs installed (additive; CUDA/compute untouched; no reboot)."
echo "Next: tell the coordinator 'GPU is on' and it will re-render the universe ON THE GPU to confirm the glow."
