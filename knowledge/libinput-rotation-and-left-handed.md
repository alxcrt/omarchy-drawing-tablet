---
type: reference
title: Rotation works only on display tablets; the left-handed flip only on reversible ones
description: Why Hyprland's transform does nothing on an external tablet, and the libwacom facts libinput consults before allowing rotation or left-handed mode
tags: [libinput, libwacom, rotation]
status: stable
verified:
  - by: reading libinput src/evdev-tablet.c (tablet_init_calibration, tablet_init_left_handed, tablet_is_display_tablet) on main, then setting transform = 1 on the One by Wacom and observing no change under the pen
    at: 2026-08-29
---

Hyprland rotates a tablet by handing libinput a calibration matrix
(`libinput_device_config_calibration_set_matrix`, `setTabletConfigs`). libinput
only initialises calibration for a tablet when

- the device has `INPUT_PROP_DIRECT` (a screen the pen touches), or
- libwacom marks the model `IntegratedIn=Display` or `System`, or
- libwacom does not know the model at all.

Otherwise the call returns "unsupported" and Hyprland ignores the status, so a
90° or 270° request on an external tablet silently does nothing. That is the
behaviour the user reported before this fact was written down.

The 180° flip is a different mechanism: `left_handed` reaches
`libinput_device_config_left_handed_set`, which libinput offers for a tablet
only when libwacom marks it `Reversible=true` or does not know it.

The plugin reads the same database (`/usr/share/libwacom/*.tablet`, matched on
`DeviceMatch=bus|vid|pid`) and the kernel's `properties` bitmask
(`/sys/class/input/eventN/device/properties`, bit 1 is DIRECT), and shows the
Rotation menu only when the tablet is rotatable and the Left-handed switch only
when it is reversible. A profile that remembers a rotation the tablet cannot do
is corrected to 0 on the next scan so the summary never claims it.

On the One by Wacom M: `Reversible=true`, `IntegratedIn=` empty, properties
`0x1` (POINTER only). Left-handed works, rotation does not.
