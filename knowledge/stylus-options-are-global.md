---
type: reference
title: Pressure range and eraser button are global, and the eraser setting needs an eraser button
description: The tablettool options Hyprland exposes, their libinput rules, and the pens they apply to
tags: [hyprland, libinput, stylus]
status: stable
verified:
  - by: reading src/config/values/ConfigValues.cpp and setTabletToolConfigs at v0.56.2, libinput libinput.h and libinput-plugin-tablet-eraser-button.c on main, and hyprctl getoption on the box
    at: 2026-08-29
---

`input:tablettool:pressure_range_min` and `pressure_range_max` default to -1
(the tool's own range). libinput requires `0 <= min < max <= 1`; the plugin
keeps at least 0.05 between them. The window is remapped so `min` reads as
pressure 0 and `max` as pressure 1 in the app.

`input:tablettool:eraser_button_mode` 1 makes libinput turn the pen's eraser
button into a plain tool button (`eraser_button_override`, an evdev code, or
the first button the pen does not already have). libinput offers this only for
pens whose eraser is a *button* (libwacom `EraserType=Button`), not for an
eraser on the back end (`Invert`). The One by Wacom's generic pen is Invert, so
the setting is inert there; the panel says so under the Stylus heading.

Tool settings are applied when the tool first appears and on every input
refresh; libinput applies the eraser mode from the tool's next proximity.

`cursor:hide_on_tablet` hides the pointer after a pen comes into proximity
until the mouse moves. It is exposed as "Hide the cursor while drawing".
