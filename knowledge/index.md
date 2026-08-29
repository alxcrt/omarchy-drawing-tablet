---
type: index
title: Platform facts behind omarchy-drawing-tablet
description: Index of the measured and source-verified facts this plugin depends on
tags: [omarchy, hyprland, libinput, libwacom, tablet]
---

# Knowledge bundle

One file per fact, each with frontmatter naming its `type` and how it was
verified. Every fact was either measured on a running Omarchy machine (Hyprland
0.56.2, libinput 1.31, libwacom 2.19.1, kernel 7.1, a Wacom One by Wacom M)
or read out of the sources at a named tag, and the file says which. Where a
fact could not be observed, the file says so rather than guessing. `log.md`
records what changed and when.

| Fact | Why it matters |
|---|---|
| [hyprland-lua-tablet-config](hyprland-lua-tablet-config.md) | `hyprctl keyword` is dead; `hyprctl eval` with `hl.device` is how a mapping is applied, and a reload wipes it |
| [tablet-mapping-units](tablet-mapping-units.md) | region is logical pixels of the bound output, active area is millimetres, and what `output` accepts |
| [libinput-rotation-and-left-handed](libinput-rotation-and-left-handed.md) | why the Rotation menu only exists for display tablets and the left-handed flip only for reversible ones |
| [hyprland-ignores-enabled-for-tablets](hyprland-ignores-enabled-for-tablets.md) | why there is no off switch |
| [pen-buttons-and-pads-on-hyprland](pen-buttons-and-pads-on-hyprland.md) | what the pen's side buttons do, why apps without tablet support cannot be clicked, and why pad keys cannot be bound |
| [stylus-options-are-global](stylus-options-are-global.md) | pressure range and eraser button apply to every tablet, and the eraser setting only to pens with an eraser button |
| [tablet-identity-from-sysfs](tablet-identity-from-sysfs.md) | udev carries no vendor or product for Bluetooth and uinput tablets |
| [tablet-driver-coverage](tablet-driver-coverage.md) | which brands work, and the `udev-hid-bpf` package newer Huion and XP-Pen models need |
| [omarchy-service-reload](omarchy-service-reload.md) | a saved file reloads the panel but not the running service |
