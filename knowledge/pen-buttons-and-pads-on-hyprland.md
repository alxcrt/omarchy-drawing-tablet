---
type: reference
title: Pen buttons go to the app, pads cannot be bound, and apps without tablet support cannot be clicked
description: What Hyprland does with stylus buttons, the eraser, pad buttons, rings and strips, read out of Tablets.cpp and protocols/Tablet.cpp
tags: [hyprland, wayland, tablet-v2]
status: stable
verified:
  - by: reading src/managers/input/Tablets.cpp, src/protocols/Tablet.cpp and src/devices/Tablet.cpp at v0.56.2, plus discussion 6226 and 12253 and issues 215, 3004, 5960
    at: 2026-08-29
---

# Stylus buttons

`onTabletButton` forwards the raw libinput button code (BTN_STYLUS 0x14b,
BTN_STYLUS2 0x14c) to `zwp_tablet_tool_v2` for the client under the pen. There
is no remapping, no bind hook, and no `wl_pointer` emulation anywhere in the
tablet path. Toolkits agree on the X-era convention: GTK 3 and 4, Qt 6,
Blender's GHOST, Xwayland and Chromium (since 2025-06-28) map BTN_STYLUS to
middle click and BTN_STYLUS2 to right click unless the app assigns them.

A client that never bound `zwp_tablet_manager_v2` gets the cursor warped and
`wl_pointer` motion while the tip is up, and keyboard focus on tip-down, but
never a click. That is why a pen can draw in Krita and hover uselessly over an
older Electron app. sway emulates a pointer in that case; Hyprland does not,
and no PR proposes it.

# Pads

Pad buttons and mode switches are broadcast to every `zwp_tablet_pad_v2`
resource without focus gating; ring and strip forwarding are `FIXME: STUB`;
dials are not advertised. Nothing in KeybindManager or the Lua layer sees a pad,
so there is no compositor-level binding. GTK apps can bind pads themselves
(`GtkPadController`); QtWayland destroys the pad group and delivers nothing,
so Krita gets no express keys on Wayland. The practical workaround people use
is input-remapper on the pad's evdev node. Consumer Wacom pads report
BTN_LEFT, BTN_RIGHT, BTN_FORWARD and BTN_BACK rather than BTN_0..N.

# What the plugin does with this

Shows the pen's button count and eraser type in the Tablet pane, and offers
to press a real mouse button for each control: `tools/pen-buttons.py` reads
the pen's evdev node (read-only, never grabbed, so libinput keeps it) and
emits BTN_LEFT/RIGHT/MIDDLE on a uinput mouse named "Drawing Tablet for
Omarchy pen buttons". A uinput device needs REL_X/REL_Y and INPUT_PROP_POINTER
to be classified as a mouse by udev and libinput even though it never moves;
verified by Hyprland listing it under `mice`. The click lands where the
tablet already warped the cursor. The default is "let the app decide", since
tablet-aware apps also receive the raw button and would act twice.

`/dev/uinput` is root:root 0600 by default; on this box it was open to the
user through Steam's `60-steam-input.rules` (`TAG+="uaccess"`). The plugin
ships the same one-line rule for machines without it, installed with sudo
through Omarchy's presented terminal.

Tip clicks are not emulated on purpose: Hyprland suppresses pointer motion
while the tip is down, so a synthetic left click could press but never drag.

## Kernel key capabilities vs libwacom (2026-08-29)

`libwacom-list-local-devices` lists styli `0xfffff` ("General Pen") and `0xffffe` ("General Pen Eraser") when it has no stylus data for the tablet (`WACOM_STYLUS_FALLBACK_ID` / `WACOM_ERASER_FALLBACK_ID` in libwacom). The One by Wacom CTL-672 is such a case: the kernel advertises `BTN_TOOL_RUBBER`, `BTN_STYLUS` and `BTN_STYLUS2` (`/sys/class/input/eventN/device/capabilities/key` = `1c03 0 0 0 0 0`) because the tablet accepts an eraser-equipped pen, but the LP-190 pen in the box has two switches and no eraser. The probe now reads `capabilities/key` and the panel says "eraser if the pen has one" instead of claiming one.

## Middle click pastes in browsers

A middle click from the virtual mouse behaves like any middle click on Linux: Chromium and Firefox paste the primary selection on release, so in Excalidraw a pan with a pen button mapped to middle click ends with a paste. The "Hold Space" action (a second uinput device, a keyboard advertising ESC..D plus Space so udev tags it `ID_INPUT_KEYBOARD`) gives the pan gesture of Excalidraw, Krita, GIMP and Inkscape without that.

## Wayland virtual input instead of uinput (2026-08-29, v1.2.0)

Hyprland offers `zwlr_virtual_pointer_manager_v1` (v2) and `zwp_virtual_keyboard_manager_v1` (v1) to every client, so the helper now speaks the Wayland wire protocol directly (standard library only: unix socket, `wl_registry.bind`, `create_virtual_pointer(seat)`, `button` + `frame`; `create_virtual_keyboard(seat)`, `keymap` over SCM_RIGHTS with a one-key xkb keymap, then `key`). The uinput path, its udev `uaccess` rule and the sudo prompt are gone; the marketplace's security baseline flagged that `sudo` as a `privilege` capability needing manual review. Only the self-test still uses `/dev/uinput`, for the fake pen on the input side, and skips when it is unavailable.

## Right clicks crash the shell on Qt 6.11 (2026-08-29)

Quickshell 0.3.1 on Qt 6.11.2 segfaults in `QQuickDeliveryAgentPrivate::contextMenuTargets` → `QQuickItem::mapToScene` whenever a right click (a `QContextMenuEvent`) reaches one of its windows: the `omarchy-background` wallpaper layer, the bar, any panel. Fourteen crashes in one afternoon, all from a pen button mapped to right click while the pen hovered over the desktop, plus the end-to-end test clicking there. `omarchy-shell` restarts Quickshell after each. The helper now asks `hyprctl -j cursorpos/clients/monitors` before a right click and sends it only when the pointer is inside a mapped window on the workspace its monitor shows. Left and middle clicks do not raise context-menu events and are unaffected. Upstream: https://github.com/quickshell-mirror/quickshell/issues/900 (open).
