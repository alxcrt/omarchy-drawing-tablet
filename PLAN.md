# omarchy-tablet — plan

A sibling of [omarchy-hyprmoncfg](https://github.com/crmne/omarchy-hyprmoncfg) for
drawing tablets: an Omarchy bar panel plus a tiny background service that maps a
pen tablet to the right screen, keeps the mapping across hotplug and Hyprland
reloads, and gives the everyday controls (target screen, proportions, rotation,
left-handed, pen/mouse mode, pressure range) a visual editor.

## What the machine has (research summary)

| Fact | Value / source |
|---|---|
| Tablet present | Wacom **One by Wacom (M)**, CTL-672, `usb:056a:037b`, serial `9JE00M1015644` |
| Kernel / evdev | `Wacom One by Wacom M Pen` on `/dev/input/event18`; ABS 21600×13500 @ 100/mm → **216 × 135 mm** active area (udev `ID_INPUT_WIDTH_MM/HEIGHT_MM`), pressure 0..2047, no tilt, no pad buttons |
| Hyprland | 0.56.2, **Lua config** (`hl.*`). `hyprctl keyword` is dead ("keyword can't work with non-legacy parsers. Use eval."); runtime changes go through `hyprctl eval 'hl.device({...})'` — the same path Omarchy's own `omarchy-toggle-input-device` uses |
| Hyprland device name | `wacom-one-by-wacom-m-pen` = kernel name, lower-cased, spaces → `-` (`deviceNameToInternalString`); listed by `hyprctl devices -j .tablets[]` |
| Per-device tablet fields accepted by `hl.device` (verified with eval) | `enabled`, `output`, `transform` (-1..7), `rotation`, `left_handed`, `relative_input`, `region_position {x,y}`, `region_size {w,h}`, `absolute_region_position`, `active_area_position {x,y}`, `active_area_size {w,h}`. vec2 is `{x, y}` or `"x y"`; `{x=…,y=…}` is rejected |
| Global stylus fields | `hl.config({ input = { tablettool = { pressure_range_min, pressure_range_max, eraser_button_mode, eraser_button_override } } })` — global only, not per device |
| Mapping semantics (PointerManager.cpp `warpAbsolute`) | `output` empty → whole layout bounding box; `output = "current"` → focused monitor; `output = <name or desc:…>` → that monitor's logical box. `region_position` translates the box (relative to its top-left unless `absolute_region_position`), `region_size` overrides its size. **Units: logical pixels.** |
| Active area (InputManager.cpp `setTabletConfigs`) | `active_area_position/size` are **millimetres**, divided by the tablet's physical size (axes swapped when `transform` is odd) |
| Reset behaviour | `hyprctl reload` re-executes the Lua config and drops runtime `hl.device` state → must re-apply on the `configreloaded` IPC event |
| Tooling on the box | `udevadm` (systemd) for device identity + hotplug monitor; `libwacom-list-local-devices --format=yaml` (libwacom ships with libinput) for model name/styli; `jq`; Quickshell 0.3.1 with `FileView.setText`, `Process`, `Quickshell.Hyprland` (`rawEvent`, `monitors`) |
| No `xsetwacom`, no OpenTabletDriver | Neither wanted: Hyprland owns tablet mapping on Wayland |

## Decisions

1. **Self-contained.** Unlike hyprmoncfg there is no AUR package or daemon to
   install. Everything is QML/JS inside the plugin; the only external
   commands are `hyprctl`, `udevadm`, `libwacom-list-local-devices`
   (optional, degrades to the kernel name) and `sh`.
2. **Two entry points, like the sibling:** `BarWidget.qml` (kind `bar-widget`,
   loads `Panel.qml`) and `Service.qml` (kind `service`). The service is what
   makes the mapping *stick*: it applies the saved profile at shell start, on
   udev `add` of an input device, on Hyprland `configreloaded`, and whenever
   the profile file changes.
3. **Runtime application only, no Hyprland config surgery.** `hyprctl eval`
   is enough on 0.55+; re-applying after `configreloaded` closes the gap a
   reload opens. That keeps `~/.config/hypr/*.lua` untouched and
   `omarchy refresh hyprland` harmless. (hyprmoncfg needs an include because
   monitors must be right before the bar exists; a tablet can wait a few ms.)
4. **Data, not code.** Device names and monitor descriptions come from USB/EDID
   descriptors. They are stored as JSON and passed to Lua only through a
   strict escaper (`\` `"` newlines; control characters rejected), and to
   processes only as argv — never through a shell string. Same rule Omarchy
   applies in `disabled-input-device.lua`.
5. **Identity, not port.** A tablet is matched by `bus:vid:pid:serial`
   (falls back to `bus:vid:pid` when the serial is empty), so the profile
   follows the device across USB ports, exactly like hyprmoncfg matches
   monitors by make/model/serial.
6. **Store intent, compute geometry at apply time.** The profile stores
   *modes* ("keep tablet proportions", "custom region as fractions of the
   screen", "active area in mm"); the pixel values are computed from the live
   `hyprctl monitors -j` when applying, so a resolution or scale change never
   stales a profile.
7. **Monitors are referenced by `desc:` when possible**, name otherwise, so a
   cable move does not break the mapping (Hyprland's `configString` lookup
   accepts both).

## Data model — `~/.config/omarchy-tablet/tablets.json`

```json
{
  "version": 1,
  "stylus": { "pressureMin": 0, "pressureMax": 1, "eraserButtonMode": 0, "eraserButtonOverride": 0 },
  "tablets": [
    {
      "id": "usb:056a:037b:9JE00M1015644",
      "label": "One by Wacom (medium)",
      "kernelName": "Wacom One by Wacom M Pen",
      "widthMm": 216, "heightMm": 135,
      "enabled": true,
      "output": { "mode": "monitor", "name": "DP-1", "description": "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622" },
      "region": { "mode": "aspect", "x": 0, "y": 0, "w": 1, "h": 1 },
      "activeArea": { "mode": "full", "x": 0, "y": 0, "w": 216, "h": 135 },
      "transform": 0,
      "leftHanded": false,
      "relativeInput": false
    }
  ]
}
```

- `output.mode`: `layout` (all monitors), `current` (follow focus), `monitor`.
- `region.mode`: `full`, `aspect` (largest tablet-proportioned box centred on
  the output — no distortion), `custom` (fractions of the output box).
- `activeArea.mode`: `full`, `aspect` (crop the tablet to the screen's
  proportions — 1:1 pen feel), `custom` (mm rectangle).
- `current` output cannot be measured ahead of time → region and active area
  are forced to `full` for it (the editor greys the choices out).

## Apply plan (pure JS in `Model.js`, unit-tested)

```
applyPlan(profile, monitorsJson) -> [{ lua: 'hl.device({ ... })' }, { lua: 'hl.config({ input = { tablettool = {...} } })' }]
```

1. Logical box per monitor: `width/scale × height/scale`, swapped for odd
   `transform`; layout box = union.
2. Effective tablet size = `widthMm × heightMm`, swapped for odd `transform`.
3. Region px from mode; active area mm from mode; integers, clamped ≥ 1.
4. Emit one `hl.device` per remembered tablet whose Hyprland name is currently
   present (`hyprctl devices -j`) — absent tablets are skipped, disabled ones
   get `enabled = false`.
5. Emit the global `hl.config` for the stylus section.
6. The caller runs `["hyprctl", "eval", lua]` per statement and reports
   `ok` / the error text in the panel status line.

## Files

| File | Role |
|---|---|
| `manifest.json` | id `io.github.alxcrt.tablet`, kinds `bar-widget` + `service`, `barWidget.schema` with `hideWhenDisconnected` |
| `BarWidget.qml` | bar icon 󰓖 (dimmed when no tablet), tooltip "Tablet · <label> → <target>", loads `Panel.qml`, exposes `open/close/toggle` like the sibling |
| `Panel.qml` | the popup; compact view (target, proportions, rotation, toggles, apply/save/reset) and expanded editor (canvas, custom numbers, stylus, tablet list, keyboard help) |
| `PanelDropdown.qml`, `EditorPane.qml`, `KeyboardHelp.qml` | copied idioms from the sibling (same look and feel) |
| `MappingCanvas.qml` | draws the monitor layout with the mapped region (drag to move / resize in custom mode) and the tablet with its active area |
| `Service.qml` | applies on start / hotplug (`udevadm monitor`) / `configreloaded` / file change; debounced |
| `Model.js` | device parsing (udev, libwacom yaml, hyprctl), identity, geometry, Lua emission, profile normalisation, plugin update check (ported) |
| `tests/model.test.js` | `node --test`, mirrors the sibling's style |
| `README.md`, `LICENSE`, `.github/workflows/{validate,release}.yml` | as the sibling |

## UI (mirrors the sibling's idiom)

Compact:
```
 󰓖 One by Wacom (medium)                    connected · DP-1
 Map to        [ Huawei ZQE-CBA (DP-1)      ▾ ]
 Proportions   [ Keep tablet proportions    ▾ ]
 Rotation      [ 0°                         ▾ ]
 [x] Left-handed   [ ] Mouse mode   [x] Enabled
 ─────────────────────────────────────────────
 Apply (a)   Save (s)   Reset (r)        Expand ▸
```
Expanded adds: the canvas (screens + region; tablet + active area), custom
region / active-area number fields, Stylus (pressure min/max sliders, eraser
button mode), Tablets (remembered devices; forget), and `?` keyboard help.
Keys: `a` apply, `s` save, `r` reset, `?` help, arrows nudge a custom region,
`Shift` fine / `Ctrl` coarse, `Esc` close.

## Empty / error states

- No tablet detected: onboarding text, and remembered profiles stay editable.
- `hyprctl eval` error: shown verbatim in the status line; profile untouched.
- Hyprland < 0.55 (no `eval`): panel explains the requirement instead of failing quietly.

## Build & verify loop

1. `omarchy plugin validate .`
2. `node --test tests/model.test.js`
3. rsync into `~/.config/omarchy/plugins/io.github.alxcrt.tablet/` (hot reload), `omarchy plugin enable io.github.alxcrt.tablet --section right`
4. `journalctl --user -o cat` for QML errors; open the panel; apply a mapping; confirm with `hyprctl eval` returning `ok`.
5. Commit.

## Out of scope for v1 (noted for later)

- Express-key / pad button bindings (Hyprland has no per-pad binding surface).
- Per-application mappings, pressure *curves* (Hyprland exposes only a range).
- Multiple named presets per tablet (one profile per tablet in v1; the compact
  "Map to" dropdown is the quick switch).
