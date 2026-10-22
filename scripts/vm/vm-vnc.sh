#!/usr/bin/env bash
# Send mouse/keyboard input to the VM (or grab its framebuffer) through the
# VM's own VNC server — input goes to the guest only, never the host desktop.
# Arguments are vncdotool commands. Their coordinates are framebuffer pixels, which are guest points × the
# framebuffer scale: 2 when the guest runs 1728x1117@2x (a 3456x2234 framebuffer), 1 when it came up at 1x (tart sizes
# a "pt" display with the host's screen scale, so a host on a 1x display gives a 1x guest; docs/testing-vm.md).
# With --points, `move` / `mousemove` / `drag` take guest points and are converted at the real scale (`vm_fb_scale`,
# against FROST_VM_POINTS_WIDTH, default 1728), so the same command works at either scale:
#   scripts/vm/vm-vnc.sh --points move 1479 14 click 1  # e.g. click the ❄ status item at x 1479 pt
#   scripts/vm/vm-vnc.sh key alt-w                      # ⌘W  (Apple's VNC server maps VNC alt → ⌘)
#   scripts/vm/vm-vnc.sh --points move 1479 14 keydown meta click 1 keyup meta   # ⌥-click (VNC meta → ⌥)
#   scripts/vm/vm-vnc.sh key alt-,                      # ⌘,  (use the literal key, not "comma")
# Modifiers: alt = ⌘, meta = ⌥, super does nothing, ctrl/shift as usual. `click 6/7` scroll.
# VNC pointer drags don't drive AppKit drag-and-drop destinations; use the guest-side
# scripts/vm/guest-drag.swift for that (see docs/testing-vm.md).
source "$(dirname "$0")/common.sh"
vm_running || die "VM '$VM_NAME' is not running (scripts/vm/vm-up.sh)"
points=0
if [[ "${1:-}" == "--points" ]]; then points=1; shift; fi
[[ $# -gt 0 ]] || die "usage: $0 [--points] <vncdotool commands...>"
if [[ $points == 1 ]]; then
  scale="$(vm_fb_scale "${FROST_VM_POINTS_WIDTH:-1728}")" || die "could not read the VNC framebuffer size"
  args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      move|mousemove|drag)
        [[ $# -ge 3 ]] || die "$1 needs x and y"
        args+=("$1" "$(awk -v v="$2" -v s="$scale" 'BEGIN { printf "%d", v * s }')" \
               "$(awk -v v="$3" -v s="$scale" 'BEGIN { printf "%d", v * s }')")
        shift 3 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
fi
vm_vncdo "$@"
