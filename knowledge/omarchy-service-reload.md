---
type: reference
title: Saving a file reloads the panel but not the running service
description: How Omarchy mounts a plugin's service kind and why new Service.qml code needs a shell restart
tags: [omarchy, quickshell, service]
status: stable
verified:
  - by: reading shell.qml ensureService and _syncServices, and watching the journal after rsyncing a changed Service.qml without and with omarchy restart shell
    at: 2026-08-29
---

A plugin listed in the bar layout counts as enabled for its `service` kind as
well; the shell creates one service instance at startup (`_syncServices`).
Saving files under `~/.config/omarchy/plugins/<id>/` logs "Local plugin
changed, reloading" and rebuilds bar widgets, but the running service instance
kept the old code until `omarchy restart shell`. `omarchy plugin validate`
refuses symlinks, so the development copy is an rsync, not a link.

Plugin `console.log` output lands in `journalctl --user` as `DEBUG qml:` lines.
The service logs `service started`, `re-applying tablet mappings (<reason>)`
and `applied N tablet mapping(s)`, which is how a re-apply is verified.

One bar widget instance exists per monitor, each with its own `TabletEngine`
and `FileView` on the profile. The engine tells its own writes apart from
outside edits by remembering the text it last wrote; only the latter raises
`externalChange`, which the service treats as a reason to re-apply. Without
that distinction every probe looked like an edit and the service looped.
