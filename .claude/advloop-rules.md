# Review rules for omarchy-tablet

An Omarchy shell plugin: QML inside the Quickshell process that draws the bar,
with the logic in `Model.js`. Judge it against these, not against generic
best practice.

## Platform facts, so a finding that ignores one is false

- `qs.Ui` and `qs.Commons` are the shell's shared component library at
  `/usr/share/omarchy/shell/`. `Panel`, `BarIconButton`, `KeyboardPanel`,
  `PanelKeyCatcher`, `PanelSectionHeader`, `PanelSlider`, `Toggle`,
  `NumberField`, `BorderSurface`, `CursorSurface`, `Style`, `Color` and
  `Border` come from there. They are not missing imports.
- Tablet settings are applied with `hyprctl eval` and `hl.device`; `hyprctl
  keyword` is refused on Lua-configured Hyprland. See `knowledge/`.
- Hyprland ignores `enabled` for tablets; libinput ignores a calibration
  matrix (Hyprland's `transform`) on external tablets and offers the
  left-handed flip only for reversible ones. A finding that asks for those
  controls back is answered with the platform fact.
- Pen buttons and pad keys are forwarded raw to the client; there is no
  remapping surface in Hyprland. Asking for one is asking for a control with
  nothing behind it.
- `region_position`/`region_size` are logical pixels of the bound output,
  `active_area_*` are millimetres, recomputed from `hyprctl monitors -j` on
  every apply.
- One panel instance per monitor, one service instance per shell. The service
  re-applies on udev input hotplug, `configreloaded`, monitor changes, and
  outside edits of the profile file.
- Keyboard behaviour cannot be driven headlessly against a layer-shell
  surface from a script; keyboard findings need a description of the keys
  pressed and what appeared.

## Binding rules

- Could this be simpler? Reuse what Omarchy ships before writing anything.
- A control that Hyprland or libinput ignores is a defect even when its code
  is correct.
- Device names and monitor descriptions are data: `luaString` for Lua, argv
  for processes, refused when they carry control characters. Every `Text`
  is `Text.PlainText`.
- Store intent, compute geometry at apply time. A stored pixel is a defect.
- Nothing is polled while idle.
- One line per comment, stating the constraint. Name every magic number, and
  put a sample input above every parser.
- Errors are shown as one sentence in the status line with Hyprland's own
  words; a parse failure yields a default shape, never a throw.
