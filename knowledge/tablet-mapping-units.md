---
type: reference
title: Region is logical pixels of the bound output, active area is millimetres
description: How Hyprland turns a tablet position into a cursor position, read out of PointerManager.cpp and InputManager.cpp
tags: [hyprland, geometry]
status: stable
verified:
  - by: reading src/pointer/PointerManager.cpp warpAbsolute and src/managers/input/InputManager.cpp setTabletConfigs at v0.56.2
    at: 2026-08-29
---

`warpAbsolute` clamps the tablet position to 0..1 on each axis, then picks a
box:

- `output` empty: the bounding box of every monitor, translated by
  `region_position` (or with `region_position` as an absolute origin when
  `absolute_region_position` is set).
- `output = "current"`: the focused monitor's logical box.
- `output` naming a monitor (`DP-1` or `desc:...`): that monitor's logical box,
  translated by `region_position`.

`region_size`, when non-zero, replaces the box's width and height. All of this
is in logical pixels (mode size divided by scale, axes swapped for a rotated
monitor), which is why the plugin recomputes the numbers from
`hyprctl monitors -j` on every apply instead of storing pixels.

`active_area_position` and `active_area_size` are millimetres of the tablet
surface, divided by the tablet's physical size, with width and height swapped
when `transform` is odd. The physical size comes from libinput, which takes it
from the kernel's axis resolution; udev exposes the same numbers as
`ID_INPUT_WIDTH_MM` and `ID_INPUT_HEIGHT_MM` (216 x 135 mm on the One by
Wacom M).

Because a region cannot be measured for `"current"` ahead of time, the panel
forces the whole screen and the whole tablet while the tablet follows focus.
