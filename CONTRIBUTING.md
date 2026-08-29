# Contributing

Thanks for looking. This plugin is three files that matter and a test suite
that keeps them honest:

- **`Model.js`** holds every decision as pure functions: what the probe output
  means, which tablet a profile belongs to, the geometry of a mapping, and the
  exact Lua sent to Hyprland. It runs under Node for the tests and inside
  Quickshell for real, so it must not touch Qt, the filesystem or the network.
- **`TabletEngine.qml`** is the only thing that talks to the outside world:
  it runs the probe, reads and writes the profile file, and calls `hyprctl`.
  The panel and the service both instantiate it, so a mapping applies the same
  way whether a person or a hotplug asked.
- **`Panel.qml`** draws the bar widget and its popup; **`Service.qml`** keeps
  the mapping in force while the panel is closed.

If a change needs a fact about Hyprland, libinput or a tablet, look in
[`knowledge/`](knowledge/index.md) first. Every fact there was measured or read
out of a named source, and several of the plugin's early mistakes came from
guessing where a file now exists.

## Build and test

```sh
node --test tests/model.test.js
omarchy plugin validate .
```

To run your change in the bar, copy the tree (the validator refuses symlinks)
and restart the shell, which is the only way a changed `Service.qml` is
reloaded:

```sh
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/io.github.alxcrt.tablet/
omarchy restart shell
journalctl --user -o cat -f | grep omarchy-tablet
```

The service logs `service started`, `re-applying tablet mappings (<reason>)`
and `applied N tablet mapping(s)`. `tools/showcase.sh` regenerates the README
images from the live panel and restores your profile afterwards.

## Prove it, then send it

The defects this plugin attracts are "the option was accepted and nothing
happened" defects, so review asks how you know. Before opening a PR:

1. **Say which tablet you tested on**, and whether it is external, a display
   tablet, or unknown to libwacom. Those three behave differently and the
   tests carry a fixture for each.
2. **Show Hyprland accepting the statement** (`hyprctl eval` answers `ok`)
   and, where the change is visible under the pen, that the pen actually does
   the new thing. A green suite proves the Lua is well formed, not that the
   compositor honours it; the Rotation menu was green for a whole afternoon
   while doing nothing on an external tablet.
3. **Where the defect is testable, write the failing case first** with a
   realistic device description (udev properties, libwacom lines) rather than
   the minimum that satisfies the parser.

If something genuinely cannot be driven (a tablet you do not own, a Bluetooth
reconnect), say so in the PR and describe what you did instead.

## House style

- **Only offer what will happen.** A control Hyprland or libinput ignores is a
  defect even when the code behind it is correct. Read the source, cite it in
  `knowledge/`, and hide the control.
- **Data, never code.** Device names and monitor descriptions come from USB and
  EDID descriptors. They reach Lua only through `luaString`, reach processes
  only as argv, and are refused when they carry control characters.
- **Compute at apply time, store intent.** Profiles say "keep the tablet's
  proportions on that screen"; pixels are worked out from the live layout.
- **Every `Text` sets `textFormat: Text.PlainText` on its first line.** A test
  checks it; device strings must not be able to inject markup.
- **Comments state the constraint, not the mechanics.** One line, two or three
  for a real timing or race constraint.
- **Name magic numbers**, and put a sample of the input directly above every
  parser.
- **No polling while idle.** The panel probes while open; the service reacts
  to udev, `configreloaded`, monitor changes and profile edits.

## Releases

`tools/release.sh X.Y.Z` bumps `manifest.json`, commits, tags `vX.Y.Z` and
pushes; the Release workflow turns the tag into a GitHub release with notes
from the commits since the previous tag. Versions follow semver: a change in
what a saved profile means is a major bump.
