---
type: reference
title: Tablets are configured through hyprctl eval, and a reload forgets it
description: The runtime path for per-device tablet settings on Lua-configured Hyprland, the fields hl.device accepts, and why the service re-applies after configreloaded
tags: [hyprland, lua, hyprctl]
status: stable
verified:
  - by: running each command against Hyprland 0.56.2 on the box and reading src/config/lua/bindings/LuaBindingsConfigRules.cpp at v0.56.2
    at: 2026-08-29
---

# The runtime path

`hyprctl keyword` refuses every request on a Lua-configured Hyprland with
"keyword can't work with non-legacy parsers. Use eval." The working path is

```
hyprctl eval 'hl.device({ name = "wacom-one-by-wacom-m-pen", output = "desc:...", region_size = {2304, 1440} })'
```

which answers `ok`, or `error: ...` with exit code 7. Omarchy's own
`omarchy-toggle-input-device` uses the same call. Global options go through
`hl.config({ input = { tablet = { ... }, tablettool = { ... } }, cursor = { ... } })`.

# Fields hl.device accepts for a tablet

`enabled`, `output`, `transform` (-1..7), `rotation`, `left_handed`,
`relative_input`, `region_position`, `region_size`, `absolute_region_position`,
`active_area_position`, `active_area_size`. A vec2 is `{x, y}` or `"x y"`;
`{x = 0, y = 0}` is rejected with "vec2 type requires exactly 2 elements".
Unknown fields are rejected by name, which is how the list above was checked.

`eraser_button_mode`, `eraser_button_override`, `pressure_range_min` and
`pressure_range_max` are not in the Lua per-device allowlist (`DEVICE_FIELDS`,
still absent on `main` at 2026-08-28), so they are global only. See
[stylus-options-are-global](stylus-options-are-global.md).

# A reload throws it away

`hyprctl reload` re-executes the Lua configuration and drops runtime `hl.device`
state, so the tablet goes back to Hyprland's defaults. The IPC socket emits
`configreloaded`, and `Service.qml` re-applies the saved profile 1.2 s after it.
Hyprland has no IPC event for input devices being added or removed;
`udevadm monitor --udev --subsystem-match=input` works without privileges and
is the hotplug signal.

# Device names

Hyprland names a device from its kernel name, lower-cased, with spaces turned
into dashes: "Wacom One by Wacom M Pen" becomes `wacom-one-by-wacom-m-pen`.
Per-device settings must target the Tablet's name, not the Tablet Pad or Tablet
Tool (`hyprctl devices -j .tablets[]`). Tools get the parent name plus a `-N`
suffix and are not listed by name at all.
