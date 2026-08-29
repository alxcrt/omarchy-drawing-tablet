---
type: log
title: Knowledge bundle changelog
description: What was added or corrected in this bundle, and when
tags: [omarchy-drawing-tablet]
---

## 2026-08-29

Bundle created after the first release and one round of source-level
verification.

- `hyprland-lua-tablet-config`: `hyprctl keyword` tried and refused on the
  box; the hl.device field list found by feeding it one field at a time and
  reading the rejections.
- `tablet-mapping-units`: read out of PointerManager.cpp after two earlier
  guesses (fractions, and pixels of the layout) proved wrong against the code.
- `libinput-rotation-and-left-handed`: written after the user reported that
  90° did nothing on the One by Wacom. The first version of the plugin offered
  every rotation to every tablet.
- `hyprland-ignores-enabled-for-tablets`: found by a research pass over
  InputManager.cpp; the plugin had shipped a switch on that field for a few
  hours.
- `pen-buttons-and-pads-on-hyprland`, `stylus-options-are-global`,
  `tablet-driver-coverage`: from a ten-agent research pass in which every
  claim was re-checked against its source by a second agent; one date (PCI
  Wacom support, 6.14 not 6.13) was corrected in that pass.
- `tablet-identity-from-sysfs`: measured with udevadm against the USB tablet
  and the Bluetooth keyboard, mouse and trackpad on the same box.
- `omarchy-service-reload`: found the hard way, when a changed Service.qml
  logged nothing until the shell was restarted, and again when the service
  re-applied in a loop because its own probes looked like file edits.
