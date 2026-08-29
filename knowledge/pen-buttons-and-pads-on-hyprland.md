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
