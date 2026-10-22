#!/usr/bin/env bash
# One-time provisioning of the Frost test VM. Idempotent; safe to re-run.
#   1. clone the Cirrus Labs macOS 26 (Tahoe) base image as $FROST_VM (frost-test)
#   2. 4 CPUs / 8 GB RAM / 1728x1117pt display (MacBook Pro 16"-like)
#   3. boot headless, install the host SSH key, switch the guest to 1728x1117 points: @2x when the host's main screen
#      is Retina, @1x otherwise (tart turns a "pt" display into pixels with the host's screen scale; the guest then
#      offers no 2x mode). The VNC tools work at either scale (`vm-vnc.sh --points`, `vm_fb_scale`).
#   4. tidy the desktop (close the Terminal window baked into the image)
# No window appears on the host at any point; nothing needs clicking.
source "$(dirname "$0")/common.sh"
IMAGE="${FROST_VM_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
if ! vm_exists; then
  log "cloning $IMAGE -> $VM_NAME (~27 GB download, ~33 GB on disk)"
  "$TART" clone "$IMAGE" "$VM_NAME"
fi
if ! vm_running; then
  "$TART" set "$VM_NAME" --cpu 4 --memory 8192 --display 1728x1117pt
fi
"$(dirname "$0")/vm-up.sh"
vm_scp "$(dirname "$0")/set-display-mode.swift" :/tmp/set-display-mode.swift
vm_ssh "swift /tmp/set-display-mode.swift 1728 1117"
vm_ssh "defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false; osascript -e 'tell application \"Terminal\" to quit' >/dev/null 2>&1; true"
vm_ssh "sw_vers -productVersion; csrutil status"
log "VNC framebuffer scale: $(vm_fb_scale 1728 || echo '?')x (pixels per point; see vm-vnc.sh --points)"
log "setup complete — next: make vm-deploy vm-run vm-shot"
