---
type: reference
title: Which tablets libinput sees, by brand
description: Kernel driver coverage for Wacom, Huion, Gaomon, XP-Pen, Ugee, Veikk and OpenTabletDriver, and the udev-hid-bpf package newer models need
tags: [kernel, drivers, huion, wacom, opentabletdriver]
status: stable
verified:
  - by: a fact-checked research pass over drivers/hid/wacom_wac.c, hid-uclogic-core.c, drivers/hid/bpf/progs, the linuxwacom Device-IDs wiki, udev-hid-bpf and OpenTabletDriver sources
    at: 2026-08-29
---

Hyprland creates a tablet for any libinput device with
`LIBINPUT_DEVICE_CAP_TABLET_TOOL`; libinput requires ABS_X/ABS_Y with
resolution and BTN_TOOL_PEN or BTN_STYLUS. So "works with Hyprland" equals
"has a kernel driver that exposes a proper pen device".

- **Wacom**: in-kernel `wacom` driver, USB, Bluetooth and I²C, with a generic
  HID catch-all since 3.18, so unlisted pens still work. The One by Wacom M
  (056a:037b) needs kernel 4.16.
- **Huion, Gaomon, XP-Pen, Ugee**: legacy shared PIDs through `hid-uclogic`
  (mainline; DIGImend's out-of-tree package is effectively discontinued). Newer
  per-PID models are fixed by HID-BPF programs the kernel ships but does not
  load: the `udev-hid-bpf` package (Arch `extra/udev-hid-bpf`) loads them.
  Without it the tablet runs in firmware mode: the pen works as a generic HID
  pen, pad buttons arrive as keyboard keys.
- **Veikk**: no upstream driver; OpenTabletDriver.
- **OpenTabletDriver**: replaces the kernel driver (module blacklist plus
  `LIBINPUT_IGNORE_DEVICE` on the kernel node). Its "Artist mode" creates a
  uinput tablet with `INPUT_PROP_DIRECT`, so libinput treats it as a display
  tablet and allows rotation; "Absolute mode" is only a mouse.

libwacom is a database, not a driver: a tablet it does not know still works,
libinput then allows rotation and left-handed mode for it, and GNOME assumes
a built-in two-button pen. The plugin shows the kernel's name in that case.
