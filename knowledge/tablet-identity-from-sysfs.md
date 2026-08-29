---
type: reference
title: udev has no vendor or product for Bluetooth and uinput tablets
description: Why identity comes from /sys/class/input/eventN/device/id and uniq rather than ID_VENDOR_ID
tags: [udev, sysfs, bluetooth]
status: stable
verified:
  - by: udevadm info on the USB tablet and on three Bluetooth HID devices on the box
    at: 2026-08-29
---

For the USB tablet udev provides `ID_BUS=usb`, `ID_VENDOR_ID=056a`,
`ID_MODEL_ID=037b` and `ID_SERIAL_SHORT=9JE00M1015644`. For the Bluetooth
devices on the same box udev provides `ID_BUS=bluetooth` and nothing else,
while sysfs has `id/vendor`, `id/product`, `id/bustype` (0x03 USB, 0x05
Bluetooth, 0x18 I²C, 0x06 virtual) and `uniq` (the Bluetooth address, or the
USB serial).

The probe therefore reads the sysfs ids and builds the identity as
`bus:vendor:product:serial`, falling back to `bus:<device name>[:uniq]` when
the ids are zero (OpenTabletDriver's uinput tablet). Nodes carrying
`LIBINPUT_IGNORE_DEVICE=1` are skipped: libinput will never make a tablet out
of them, so Hyprland never will either.

`ID_INPUT_TABLET=1` marks a pen device, `ID_INPUT_TABLET_PAD=1` a pad; the
pad is attached to the pen with the same identity. Touch surfaces on display
tablets carry `ID_INPUT_TOUCHSCREEN=1` and are not tablets.
