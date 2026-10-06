#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: scripts/run-linux-fixture.sh <fixture-binary> [args...]" >&2
  exit 2
fi
if ! command -v xvfb-run >/dev/null || ! command -v Xvfb >/dev/null; then
  echo "Xvfb is required. Refusing to use the desktop display." >&2
  exit 1
fi
LAVAPIPE="/usr/share/vulkan/icd.d/lvp_icd.json"
if [ ! -f "$LAVAPIPE" ]; then
  echo "Mesa lavapipe is required for CPU-only fixture rendering: $LAVAPIPE" >&2
  exit 1
fi

exec nice -n 10 xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp -noreset' \
  env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET -u ZERON_BROWSER_CAPTURE_WINDOW \
  GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=2 \
  VK_DRIVER_FILES="$LAVAPIPE" VK_ICD_FILENAMES="$LAVAPIPE" "$@"
