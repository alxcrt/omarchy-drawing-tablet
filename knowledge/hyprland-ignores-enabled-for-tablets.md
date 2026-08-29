---
type: reference
title: Hyprland ignores enabled for tablets
description: Why the plugin has no off switch
tags: [hyprland]
status: stable
verified:
  - by: reading src/managers/input/InputManager.cpp at v0.56.2, where the enabled field is honoured for keyboards, pointers and touch devices only, and checking that PR 14158 (input:tablet:enabled) is still open
    at: 2026-08-29
---

`hl.device({ name = ..., enabled = false })` is accepted for a tablet and does
nothing: the field is only applied to keyboards, pointers, touchpads and touch
devices. The wiki documents the same restriction. PR
[#14158](https://github.com/hyprwm/Hyprland/pull/14158) adds
`input:tablet:enabled` and was still open on 2026-08-29.

The plugin shipped a "Pen input" switch for a few hours, driving exactly that
field. It was removed once the source was read, because a switch that does
nothing teaches the person that the plugin is broken. When the PR merges, the
switch can come back behind a version check.
