const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const PROBE = [
  "== device /sys/class/input/event18",
  "NAME=Wacom One by Wacom M Pen",
  "UNIQ=",
  "PHYS=usb-0000:00:14.0-3.4.4/input0",
  "PROPS=1",
  "KEYS=1c03 0 0 0 0 0",
  "ABS=3000003",
  "BUSTYPE=0003",
  "VENDOR=056a",
  "PRODUCT=037b",
  "DEVNAME=/dev/input/event18",
  "ID_INPUT=1",
  "ID_INPUT_TABLET=1",
  "ID_INPUT_WIDTH_MM=216",
  "ID_INPUT_HEIGHT_MM=135",
  "ID_BUS=usb",
  "ID_MODEL=CTL-672",
  "ID_MODEL_ID=037b",
  "ID_SERIAL_SHORT=9JE00M1015644",
  "ID_VENDOR=Wacom_Co._Ltd.",
  "ID_VENDOR_ENC=Wacom\\x20Co.\\x2cLtd.",
  "ID_VENDOR_ID=056a",
  "== device /sys/class/input/event19",
  "NAME=Wacom One by Wacom M Pad",
  "UNIQ=",
  "PHYS=usb-0000:00:14.0-3.4.4/input1",
  "DEVNAME=/dev/input/event19",
  "ID_INPUT=1",
  "ID_INPUT_TABLET_PAD=1",
  "ID_BUS=usb",
  "ID_MODEL_ID=037b",
  "ID_SERIAL_SHORT=9JE00M1015644",
  "ID_VENDOR_ID=056a",
  "== libwacomdb",
  "/usr/share/libwacom/wacom-one-by-wacom-m-p2.tablet:ModelName=CTL-672",
  "/usr/share/libwacom/wacom-one-by-wacom-m-p2.tablet:DeviceMatch=usb|056a|037b",
  "/usr/share/libwacom/wacom-one-by-wacom-m-p2.tablet:Class=Bamboo",
  "/usr/share/libwacom/wacom-one-by-wacom-m-p2.tablet:IntegratedIn=",
  "/usr/share/libwacom/wacom-one-by-wacom-m-p2.tablet:Reversible=true",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:ModelName=DTK-1660",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:DeviceMatch=usb|056a|0390;bluetooth|056a|0391",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:IntegratedIn=Display",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:Reversible=false",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:Buttons=8",
  "/usr/share/libwacom/wacom-cintiq-16.tablet:NumRings=1",
  "== libwacom",
  "devices:",
  "  - name: 'One by Wacom (medium)'",
  "    bus: 'usb'",
  "    vid: 0x056a",
  "    pid: 0x037b",
  "    nodes: ",
  "      - /dev/input/event18: 'Wacom One by Wacom M Pen'",
  "    styli:",
  "      - id: 0xffffe",
  "        vid: 0x0000",
  "        name: 'General Pen Eraser'",
  "        type: 'general'",
  "        axes: ['x', 'y' , 'tilt', 'distance', 'pressure']",
  "        buttons: 2",
  "        is_eraser: 'true'",
  "        eraser_type: 'invert'",
  "      - id: 0xfffff",
  "        vid: 0x0000",
  "        name: 'General Pen'",
  "        type: 'general'",
  "        axes: ['x', 'y' , 'tilt', 'distance', 'pressure']",
  "        buttons: 2",
  "        erasers: [0xffffe]",
  "== hyprland",
  '{"mice":[],"keyboards":[],"tablets":[{"address":"0x1","name":"wacom-one-by-wacom-m-pen"}],"touch":[],"switches":[]}',
  "== monitors",
  '[{"name":"eDP-1","description":"AU Optronics 0x37AC","width":1920,"height":1200,"scale":1,"transform":0,"x":0,"y":0,"focused":false,"disabled":false},' +
  '{"name":"DP-1","description":"Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622","width":3440,"height":1440,"scale":1,"transform":0,"x":-760,"y":-1440,"focused":true,"disabled":false}]',
  "== end",
  ""
].join("\n")

const MONITORS = Model.parseProbe(PROBE).monitors

function profileFor(overrides) {
  const base = Model.defaultProfile({
    id: "usb:056a:037b:9JE00M1015644",
    label: "One by Wacom (medium)",
    kernelName: "Wacom One by Wacom M Pen",
    widthMm: 216,
    heightMm: 135
  })
  return Object.assign(base, overrides || {})
}

test("Hyprland device names are the kernel name lower-cased with dashes", () => {
  assert.equal(Model.hyprlandDeviceName("Wacom One by Wacom M Pen"), "wacom-one-by-wacom-m-pen")
  assert.equal(Model.hyprlandDeviceName("🌽 Corne Keyboard"), "🌽-corne-keyboard")
  assert.equal(Model.hyprlandDeviceName(""), "")
})

test("the probe is a single argv command that never interpolates device data", () => {
  const command = Model.probeCommand()
  assert.equal(command[0], "sh")
  assert.equal(command[1], "-c")
  assert.match(command[2], /udevadm info -q property/)
  assert.match(command[2], /libwacom-list-local-devices --format=yaml/)
  assert.match(command[2], /hyprctl -j devices/)
  assert.match(command[2], /hyprctl -j monitors/)
  assert.deepEqual(Model.hyprctlEvalCommand("hl.device({})"), ["hyprctl", "eval", "hl.device({})"])
})

test("the probe parser finds the tablet, its model, its size, and Hyprland's name for it", () => {
  const probe = Model.parseProbe(PROBE)
  assert.equal(probe.tablets.length, 1)
  const tablet = probe.tablets[0]
  assert.equal(tablet.id, "usb:056a:037b:9JE00M1015644")
  assert.equal(tablet.label, "One by Wacom (medium)")
  assert.equal(tablet.vendor, "Wacom Co.,Ltd.")
  assert.equal(tablet.kernelName, "Wacom One by Wacom M Pen")
  assert.equal(tablet.hyprlandName, "wacom-one-by-wacom-m-pen")
  assert.equal(tablet.present, true)
  assert.equal(tablet.widthMm, 216)
  assert.equal(tablet.heightMm, 135)
  assert.equal(tablet.hasPad, true)
  // libwacom only offered its generic pen and eraser (0xfffff / 0xffffe),
  // so the pen is unknown: the kernel says two switches and an eraser tool
  // the tablet would accept, not that the pen in the box has one.
  assert.equal(tablet.penButtons, 2)
  assert.equal(tablet.eraserType, "unknown")
  assert.equal(tablet.penKnown, false)
  assert.equal(Model.penLabel(tablet), "2 buttons · eraser if the pen has one")
  assert.equal(Model.anyEraserButton([tablet]), false)
  assert.equal(tablet.known, true)
  assert.equal(tablet.display, false)
  assert.equal(tablet.rotatable, false)
  assert.equal(tablet.reversible, true)
  assert.equal(Model.rotationSupportLabel(tablet), "180° only, via Left-handed (external tablet)")
  assert.equal(Model.padLabel(tablet), "present (not managed here)")
  // The kernel's word, not libwacom's generic pen (which would claim tilt and an eraser).
  assert.deepEqual(tablet.penAxes, ["pressure", "distance"])
  assert.equal(Model.stylusSummary(tablet), "pressure · 2 buttons")
  assert.equal(Model.tabletSizeLabel(tablet), "216 × 135 mm")
  assert.deepEqual(probe.hyprlandNames, ["wacom-one-by-wacom-m-pen"])
  assert.equal(probe.monitors.length, 2)
  assert.deepEqual(probe.monitors[1], {
    name: "DP-1",
    description: "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622",
    x: -760, y: -1440, width: 3440, height: 1440, scale: 1, transform: 0, focused: true
  })
})

test("a tablet without a libwacom entry or a serial still gets a stable identity", () => {
  const records = [{
    name: "XP-PEN Deco 01 Pen",
    uniq: "",
    props: { ID_INPUT_TABLET: "1", ID_BUS: "usb", ID_VENDOR_ID: "28bd", ID_MODEL_ID: "0094", DEVNAME: "/dev/input/event7" }
  }]
  const tablets = Model.discoverTablets(records, [], [])
  assert.equal(tablets.length, 1)
  assert.equal(tablets[0].id, "usb:28bd:0094")
  assert.equal(tablets[0].label, "XP-PEN Deco 01 Pen")
  assert.equal(tablets[0].present, false)
  assert.equal(Model.tabletSizeLabel(tablets[0]), "size unknown")
})

test("what libinput allows is read from libwacom the way libinput reads it", () => {
  const db = Model.parseLibwacomDb(Model.splitProbeSections(PROBE).libwacomdb)
  const cintiq = { name: "Wacom Cintiq 16 Pen", uniq: "", properties: 0x03, props: { ID_INPUT_TABLET: "1", ID_BUS: "usb", ID_VENDOR_ID: "056a", ID_MODEL_ID: "0390", DEVNAME: "/dev/input/event5" } }
  const unknown = { name: "Mystery Pen", uniq: "", properties: 0x01, props: { ID_INPUT_TABLET: "1", ID_BUS: "usb", ID_VENDOR_ID: "1234", ID_MODEL_ID: "5678", DEVNAME: "/dev/input/event6" } }
  const tablets = Model.discoverTablets([cintiq, unknown], [], [], db)
  const display = tablets.find(t => t.kernelName === "Wacom Cintiq 16 Pen")
  assert.equal(display.display, true)
  assert.equal(display.rotatable, true)
  assert.equal(display.reversible, false)
  assert.equal(display.padButtons, 8)
  assert.equal(Model.padLabel(display), "8 buttons, 1 ring (not managed here)")
  assert.equal(Model.rotationSupportLabel(display), "any angle (display tablet)")
  // A bluetooth match in the same entry resolves too.
  assert.equal(Model.libwacomEntryFor(db, "bluetooth", "056a", "0391").modelName, "DTK-1660")
  const mystery = tablets.find(t => t.kernelName === "Mystery Pen")
  assert.equal(mystery.known, false)
  assert.equal(mystery.rotatable, true)
  assert.equal(mystery.reversible, true)
})

test("a rotation the tablet cannot do is neither sent to Hyprland nor remembered", () => {
  const profile = profileFor({ transform: 1, rotatable: false, activeArea: { mode: "custom", x: 0, y: 0, w: 500, h: 500 } })
  assert.equal(Model.effectiveTransform(profile), 0)
  assert.deepEqual(Model.effectiveTabletSize(profile), { width: 216, height: 135 })
  assert.match(Model.deviceStatement(profile, MONITORS).lua, /transform = 0,/)
  assert.equal(Model.mappingSummary(profile, MONITORS), "all screens")
  const merged = Model.mergeDiscovered(Model.normalizeDocument({ tablets: [profileFor({ transform: 3 })] }), [{
    id: "usb:056a:037b:9JE00M1015644", label: "One by Wacom (medium)", kernelName: "Wacom One by Wacom M Pen", widthMm: 216, heightMm: 135, rotatable: false, reversible: true
  }])
  assert.equal(merged.document.tablets[0].transform, 0)
  assert.equal(merged.document.tablets[0].rotatable, false)
  const flipped = Model.deviceStatement(profileFor({ leftHanded: true, reversible: false }), MONITORS)
  assert.match(flipped.lua, /left_handed = false/)
})

test("touch surfaces on display tablets are not mistaken for pens", () => {
  const records = [
    { name: "Wacom Cintiq Pen", uniq: "", props: { ID_INPUT_TABLET: "1", ID_BUS: "usb", ID_VENDOR_ID: "056a", ID_MODEL_ID: "0001", DEVNAME: "/dev/input/event3" } },
    { name: "Wacom Cintiq Finger", uniq: "", props: { ID_INPUT_TABLET: "1", ID_INPUT_TOUCHSCREEN: "1", ID_BUS: "usb", ID_VENDOR_ID: "056a", ID_MODEL_ID: "0001", DEVNAME: "/dev/input/event4" } }
  ]
  const tablets = Model.discoverTablets(records, [], [])
  assert.equal(tablets.length, 1)
  assert.equal(tablets[0].kernelName, "Wacom Cintiq Pen")
})

test("monitor boxes are logical: scale divides and odd transforms swap", () => {
  const boxes = Model.parseMonitors(JSON.stringify([
    { name: "DP-2", description: "Dell U2720Q", width: 3840, height: 2160, scale: 2, transform: 1, x: 100, y: 0, focused: false },
    { name: "HDMI-A-1", description: "off", width: 1920, height: 1080, scale: 1, transform: 0, x: 0, y: 0, disabled: true }
  ]))
  assert.equal(boxes.length, 1)
  assert.equal(boxes[0].width, 1080)
  assert.equal(boxes[0].height, 1920)
  assert.deepEqual(Model.layoutBounds(MONITORS), { x: -760, y: -1440, width: 3440, height: 2640 })
})

test("Lua strings are escaped and control characters are refused", () => {
  assert.equal(Model.luaString('a"b\\c'), '"a\\"b\\\\c"')
  assert.equal(Model.luaString("evil\nname"), '""')
  assert.equal(Model.safeText("fine name"), "fine name")
  assert.equal(Model.safeText("badname"), "")
  assert.equal(Model.luaVec(1.23456, -4), "{1.235, -4}")
})

test("a default profile mirrors Hyprland's defaults so applying it changes nothing", () => {
  const statement = Model.deviceStatement(profileFor(), MONITORS)
  assert.equal(statement.lua,
    'hl.device({ name = "wacom-one-by-wacom-m-pen", output = "", transform = 0, left_handed = false, relative_input = false, absolute_region_position = false, region_position = {0, 0}, region_size = {0, 0}, active_area_position = {0, 0}, active_area_size = {0, 0} })')
  assert.deepEqual(statement.notes, [])
})

test("mapping to a screen binds by description and keeps the tablet's proportions", () => {
  const profile = profileFor({
    output: { mode: "monitor", name: "DP-1", description: "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622" },
    region: { mode: "aspect", x: 0, y: 0, w: 1, h: 1 }
  })
  const statement = Model.deviceStatement(profile, MONITORS)
  assert.match(statement.lua, /output = "desc:Huawei Technologies Co\. Inc\. ZQE-CBA 0xC080F622"/)
  // 216:135 = 1.6 on a 3440x1440 screen: full height, 2304 wide, centred.
  assert.match(statement.lua, /region_position = \{568, 0\}/)
  assert.match(statement.lua, /region_size = \{2304, 1440\}/)
  assert.match(statement.lua, /active_area_size = \{0, 0\}/)
})

test("matching the screen's proportions crops the tablet in millimetres", () => {
  const profile = profileFor({
    output: { mode: "monitor", name: "DP-1", description: "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622" },
    activeArea: { mode: "aspect", x: 0, y: 0, w: 0, h: 0 }
  })
  const area = Model.activeAreaMm(profile, Model.outputTarget(profile, MONITORS).box)
  // 3440:1440 = 2.389 is wider than 216:135, so the full width is kept and
  // the height shrinks to 216 / 2.389 = 90.4 mm, centred vertically.
  assert.deepEqual(area, { x: 0, y: 22.3, w: 216, h: 90.4 })
  const statement = Model.deviceStatement(profile, MONITORS)
  assert.match(statement.lua, /active_area_position = \{0, 22\.3\}/)
  assert.match(statement.lua, /active_area_size = \{216, 90\.4\}/)
})

test("a 90 degree transform swaps the tablet's axes before the active area is computed", () => {
  const profile = profileFor({ transform: 1, activeArea: { mode: "custom", x: 0, y: 0, w: 500, h: 500 } })
  assert.deepEqual(Model.effectiveTabletSize(profile), { width: 135, height: 216 })
  const area = Model.activeAreaMm(profile, null)
  assert.deepEqual(area, { x: 0, y: 0, w: 135, h: 216 })
})

test("custom regions are fractions of the target and are clamped inside it", () => {
  const profile = profileFor({
    output: { mode: "monitor", name: "eDP-1", description: "AU Optronics 0x37AC" },
    region: { mode: "custom", x: 0.5, y: 0.5, w: 0.75, h: 0.75 }
  })
  assert.deepEqual(profile.region, { mode: "custom", x: 0.5, y: 0.5, w: 0.75, h: 0.75 })
  const normalized = Model.normalizeProfile(profile, null)
  assert.deepEqual(normalized.region, { mode: "custom", x: 0.25, y: 0.25, w: 0.75, h: 0.75 })
  const pixels = Model.regionPixels(normalized, Model.outputTarget(normalized, MONITORS).box)
  assert.deepEqual(pixels, { x: 480, y: 300, w: 1440, h: 900 })
})

test("following the focused screen leaves the region and area to Hyprland", () => {
  const profile = profileFor({
    output: { mode: "current", name: "", description: "" },
    region: { mode: "aspect", x: 0, y: 0, w: 1, h: 1 },
    activeArea: { mode: "aspect", x: 0, y: 0, w: 0, h: 0 }
  })
  const statement = Model.deviceStatement(profile, MONITORS)
  assert.match(statement.lua, /output = "current"/)
  assert.match(statement.lua, /region_size = \{0, 0\}/)
  assert.match(statement.lua, /active_area_size = \{0, 0\}/)
})

test("a screen that is not connected falls back to all screens with a note", () => {
  const profile = profileFor({ output: { mode: "monitor", name: "DP-3", description: "LG Electronics LG ULTRAGEAR 0x1234" } })
  const statement = Model.deviceStatement(profile, MONITORS)
  assert.match(statement.lua, /output = ""/)
  assert.deepEqual(statement.notes, ["One by Wacom (medium): LG Electronics LG ULTRAGEAR is not connected, so it is mapped to all screens for now"])
})

test("Hyprland is never asked to enable or disable a tablet, which it would ignore", () => {
  const statement = Model.deviceStatement(profileFor({ enabled: false }), MONITORS)
  assert.doesNotMatch(statement.lua, /enabled/)
  assert.equal(Model.normalizeProfile({ enabled: false }, null).enabled, undefined)
})

test("identity comes from the kernel's ids, so Bluetooth and virtual tablets are stable too", () => {
  const bluetooth = { name: "Wacom Intuos BT M Pen", uniq: "aa:bb:cc:dd:ee:ff", bustype: 0x05, vendor: "056a", product: "0378", properties: 0x01,
    props: { ID_INPUT_TABLET: "1", ID_BUS: "bluetooth", DEVNAME: "/dev/input/event9" } }
  assert.equal(Model.tabletIdentity(bluetooth), "bluetooth:056a:0378:aa:bb:cc:dd:ee:ff")
  const otd = { name: "OpenTabletDriver Virtual Artist Tablet", uniq: "", bustype: 0x06, vendor: "0", product: "0", properties: 0x03,
    props: { ID_INPUT_TABLET: "1", DEVNAME: "/dev/input/event30", ID_INPUT_WIDTH_MM: "152", ID_INPUT_HEIGHT_MM: "95" } }
  assert.equal(Model.tabletIdentity(otd), "virtual:opentabletdriver-virtual-artist-tablet")
  const ignored = { name: "Wacom Intuos S Pen", uniq: "", bustype: 0x03, vendor: "056a", product: "0374", properties: 0x01,
    props: { ID_INPUT_TABLET: "1", LIBINPUT_IGNORE_DEVICE: "1", DEVNAME: "/dev/input/event8" } }
  const tablets = Model.discoverTablets([bluetooth, otd, ignored], [], ["opentabletdriver-virtual-artist-tablet"], {})
  assert.deepEqual(tablets.map(t => t.id).sort(), ["bluetooth:056a:0378:aa:bb:cc:dd:ee:ff", "virtual:opentabletdriver-virtual-artist-tablet"])
  const virtual = tablets.find(t => t.bus === "virtual")
  // OpenTabletDriver's virtual tablet is INPUT_PROP_DIRECT and unknown to
  // libwacom, so libinput lets it rotate and flip.
  assert.equal(virtual.display, true)
  assert.equal(virtual.rotatable, true)
  assert.equal(virtual.reversible, true)
  assert.equal(virtual.present, true)
  assert.equal(Model.busName(0x18, ""), "i2c")
})

test("a digitizer built into the laptop is mapped to the laptop panel by default", () => {
  const builtin = { id: "i2c:056a:4877", label: "Wacom HID 4877", kernelName: "Wacom HID 4877 Pen", widthMm: 300, heightMm: 190,
    display: true, integratedIn: "Display;System", rotatable: true, reversible: false }
  const merged = Model.mergeDiscovered(Model.parseDocument(""), [builtin], MONITORS)
  assert.deepEqual(merged.document.tablets[0].output, { mode: "monitor", name: "eDP-1", description: "AU Optronics 0x37AC" })
  const external = { id: "usb:056a:0390", label: "Cintiq 16", kernelName: "Wacom Cintiq 16 Pen", widthMm: 344, heightMm: 194,
    display: true, integratedIn: "Display", rotatable: true, reversible: false }
  assert.equal(Model.mergeDiscovered(Model.parseDocument(""), [external], MONITORS).document.tablets[0].output.mode, "layout")
})

test("the apply plan only speaks to tablets Hyprland currently lists and ends with the stylus and cursor", () => {
  const document = Model.normalizeDocument({
    tablets: [
      profileFor(),
      Model.defaultProfile({ id: "usb:28bd:0094", label: "Deco", kernelName: "XP-PEN Deco 01 Pen", widthMm: 254, heightMm: 158 })
    ],
    stylus: { pressureRangeEnabled: true, pressureMin: 0.1, pressureMax: 0.9, eraserButtonMode: 1, eraserButtonOverride: 331 }
  })
  const plan = Model.applyPlan(document, MONITORS, ["wacom-one-by-wacom-m-pen"])
  assert.equal(plan.statements.length, 3)
  assert.equal(plan.statements[0].id, "usb:056a:037b:9JE00M1015644")
  assert.equal(plan.statements[1].lua,
    "hl.config({ input = { tablettool = { pressure_range_min = 0.1, pressure_range_max = 0.9, eraser_button_mode = 1, eraser_button_override = 331 } } })")
  assert.equal(plan.statements[2].lua, "hl.config({ cursor = { hide_on_tablet = false } })")
  assert.equal(Model.cursorStatement({ hideCursor: true }), "hl.config({ cursor = { hide_on_tablet = true } })")
})

test("an unlimited pressure range hands the tool's own range back to Hyprland", () => {
  assert.equal(Model.stylusStatement(Model.defaultStylus()),
    "hl.config({ input = { tablettool = { pressure_range_min = -1, pressure_range_max = -1, eraser_button_mode = 0, eraser_button_override = 0 } } })")
  assert.equal(Model.normalizeStylus({ eraserButtonOverride: 5 }).eraserButtonOverride, 0)
  // libinput wants 0 <= min < max <= 1.
  assert.deepEqual([Model.normalizeStylus({ pressureMin: 0.8, pressureMax: 0.2 }).pressureMin, Model.normalizeStylus({ pressureMin: 0.8, pressureMax: 0.2 }).pressureMax], [0.8, 0.85])
  assert.deepEqual([Model.normalizeStylus({ pressureMin: 1, pressureMax: 1 }).pressureMin, Model.normalizeStylus({ pressureMin: 1, pressureMax: 1 }).pressureMax], [0.95, 1])
  assert.equal(Model.normalizeStylus({ pressureMin: 0, pressureMax: 0 }).pressureMax, 0.05)
})

test("documents round-trip, tolerate garbage, and refuse duplicates", () => {
  assert.deepEqual(Model.parseDocument("not json"), { version: 1, stylus: Model.defaultStylus(), tablets: [] })
  const document = Model.upsertProfile(Model.parseDocument(""), profileFor({ transform: 3, leftHanded: true }))
  const text = Model.serializeDocument(document)
  const back = Model.parseDocument(text)
  assert.equal(back.tablets.length, 1)
  assert.equal(back.tablets[0].transform, 3)
  assert.equal(back.tablets[0].leftHanded, true)
  const duplicated = Model.normalizeDocument({ tablets: [profileFor(), profileFor()] })
  assert.equal(duplicated.tablets.length, 1)
  assert.equal(Model.removeProfile(back, "usb:056a:037b:9JE00M1015644").tablets.length, 0)
})

test("newly seen tablets get a default profile and known ones refresh their size", () => {
  const probe = Model.parseProbe(PROBE)
  const first = Model.mergeDiscovered(Model.parseDocument(""), probe.tablets)
  assert.equal(first.added, 1)
  assert.equal(first.document.tablets[0].kernelName, "Wacom One by Wacom M Pen")
  first.document.tablets[0].widthMm = 1
  const second = Model.mergeDiscovered(first.document, probe.tablets)
  assert.equal(second.added, 0)
  assert.equal(second.changed, true)
  assert.equal(second.document.tablets[0].widthMm, 216)
  assert.equal(Model.mergeDiscovered(second.document, probe.tablets).changed, false)
})

test("saving goes through argv with an atomic rename", () => {
  const command = Model.saveCommand("/home/me/.config/omarchy-drawing-tablet/tablets.json", "{}")
  assert.equal(command[0], "sh")
  assert.equal(command[3], "sh")
  assert.equal(command[4], "/home/me/.config/omarchy-drawing-tablet/tablets.json")
  assert.equal(command[5], "{}")
  assert.match(command[2], /mkdir -p -- "\$dir"/)
  assert.match(command[2], /mv -f -- "\$tmp" "\$1"/)
  assert.doesNotMatch(command[2], /\$2[^"]/)
  assert.equal(Model.documentPath("/home/me"), "/home/me/.config/omarchy-drawing-tablet/tablets.json")
})

test("output options list every screen and the value round-trips through the profile", () => {
  const options = Model.outputOptions(MONITORS)
  assert.deepEqual(options.map(o => o.value), ["layout", "current", "monitor:eDP-1", "monitor:DP-1"])
  assert.equal(options[3].label, "Huawei Technologies Co. Inc. ZQE-CBA (DP-1)")
  const profile = Model.withOutputValue(profileFor(), "monitor:DP-1", MONITORS)
  assert.deepEqual(profile.output, { mode: "monitor", name: "DP-1", description: "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622" })
  assert.equal(Model.outputValue(profile), "monitor:DP-1")
  assert.equal(Model.outputValue(Model.withOutputValue(profile, "current", MONITORS)), "current")
})

test("the summary reads like a sentence fragment for the tooltip", () => {
  const profile = profileFor({
    output: { mode: "monitor", name: "DP-1", description: "Huawei Technologies Co. Inc. ZQE-CBA 0xC080F622" },
    region: { mode: "aspect", x: 0, y: 0, w: 1, h: 1 },
    transform: 2,
    leftHanded: true
  })
  assert.equal(Model.mappingSummary(profile, MONITORS), "DP-1 · tablet proportions · rotate 180° · left-handed")
  assert.equal(Model.mappingSummary(profileFor({ relativeInput: true }), MONITORS), "all screens · mouse mode")
})

test("the canvas places the region inside the target screen's rectangle", () => {
  const profile = profileFor({
    output: { mode: "monitor", name: "eDP-1", description: "AU Optronics 0x37AC" },
    region: { mode: "custom", x: 0.25, y: 0.25, w: 0.5, h: 0.5 }
  })
  const screen = Model.layoutRect(MONITORS[0], Model.layoutBounds(MONITORS), 400, 300, 8)
  const region = Model.regionCanvasRect(profile, MONITORS, 400, 300, 8)
  assert.ok(Math.abs(region.x - (screen.x + screen.width * 0.25)) < 0.001)
  assert.ok(Math.abs(region.width - screen.width * 0.5) < 0.001)
  assert.equal(region.follows, false)
  const dragged = Model.regionFromCanvasDrag(profile, MONITORS, 400, 300, 8, screen.width * 0.1, 0)
  assert.ok(Math.abs(dragged.x - 0.35) < 0.001)
  const nudged = Model.nudgeRegion(profile, 0.5, 0, 0, 0)
  assert.equal(nudged.x, 0.5)
  const follows = Model.regionCanvasRect(profileFor({ output: { mode: "current", name: "", description: "" } }), MONITORS, 400, 300, 8)
  assert.equal(follows.follows, true)
})

test("Hyprland must be new enough to accept Lua over hyprctl eval", () => {
  assert.equal(Model.hyprlandSupportsEval("Hyprland 0.56.2 built from branch v0.56.2 at commit abc"), true)
  assert.equal(Model.hyprlandSupportsEval("Hyprland 0.55.0 built from branch main"), true)
  assert.equal(Model.hyprlandSupportsEval("Hyprland 0.54.1 built from branch v0.54.1"), false)
  assert.equal(Model.hyprlandSupportsEval("Hyprland 1.0.0"), true)
  assert.equal(Model.hyprlandSupportsEval(""), false)
})

test("the plugin update check is throttled, refuses symlinked stamps, and updates through omarchy", () => {
  const command = Model.pluginUpdateCheckCommand("io.github.alxcrt.drawing-tablet", 6)
  assert.equal(command[0], "sh")
  assert.equal(command[3], "sh")
  assert.equal(command[4], "io.github.alxcrt.drawing-tablet")
  assert.equal(command[5], "6")
  assert.match(command[2], /\[ ! -L "\$stamp" \] \|\| exit 6/)
  assert.match(command[2], /exit 10/)
  assert.match(command[2], /find "\$stamp" -newermt "-\$2 hours"/)
  // touch --no-dereference does not create a missing file, which silently
  // broke the check on every fresh install.
  assert.doesNotMatch(command[2], /touch/)
  assert.match(command[2], /\(umask 077; : > "\$stamp"\)/)
  assert.deepEqual(Model.pluginUpdateCommand("io.github.alxcrt.drawing-tablet"), ["omarchy", "plugin", "update", "io.github.alxcrt.drawing-tablet", "--yes"])
  assert.equal(Model.pluginUpdated("Updated io.github.alxcrt.drawing-tablet."), true)
  assert.equal(Model.pluginUpdated("io.github.alxcrt.drawing-tablet is up to date."), false)
  assert.deepEqual(Model.shellRestartCommand(), ["setsid", "-f", "omarchy-restart-shell"])
})

test("every Text in the QML renders plain text so device names cannot inject markup", () => {
  const files = fs.readdirSync(path.join(__dirname, "..")).filter(name => name.endsWith(".qml"))
  assert.ok(files.length > 0)
  for (const file of files) {
    const qml = fs.readFileSync(path.join(__dirname, "..", file), "utf8")
    const blocks = qml.split(/\n\s*Text \{/).slice(1)
    for (const block of blocks) {
      assert.match(block, /^\s*textFormat: Text\.PlainText/, file + " has a Text without textFormat: Text.PlainText as its first line")
    }
  }
})

test("pen buttons become a plan for the helper only when something is mapped and the tablet is present", () => {
  const probe = Model.parseProbe(PROBE)
  const document = Model.upsertProfile(Model.parseDocument(""), profileFor())
  assert.deepEqual(Model.penButtonPlan(document, probe.tablets), { tablets: [] })
  assert.equal(Model.penButtonSummary(document.tablets[0]), "apps decide")
  const mapped = Model.upsertProfile(document, profileFor({ buttons: { button1: "right", button2: "middle", eraser: "bogus" } }))
  assert.deepEqual(mapped.tablets[0].buttons, { button1: "right", button2: "middle", eraser: "app" })
  assert.equal(Model.penButtonSummary(mapped.tablets[0]), "button 1 → right click · button 2 → middle click")
  const panning = Model.upsertProfile(document, profileFor({ buttons: { button1: "space", button2: "app", eraser: "app" } }))
  assert.equal(Model.penButtonSummary(panning.tablets[0]), "button 1 → hold Space")
  assert.ok(Model.buttonActionOptions().some(o => o.value === "space"))
  assert.ok(Model.buttonActionOptions().some(o => o.value === "scroll"))
  const scrolled = Model.upsertProfile(document, profileFor({ buttons: { button1: "scroll", button2: "app", eraser: "app" } }))
  assert.equal(Model.penButtonSummary(scrolled.tablets[0]), "button 1 → scroll the page")
  const plan = Model.penButtonPlan(mapped, probe.tablets)
  assert.deepEqual(plan, { tablets: [{ node: "/dev/input/event18", label: "One by Wacom (medium)", actions: { button1: "right", button2: "middle", eraser: "app" } }] })
  // Unplugged: nothing for the helper to read.
  assert.deepEqual(Model.penButtonPlan(mapped, []), { tablets: [] })
  const command = Model.penButtonsCommand("/home/me/.config/omarchy/plugins/x/", plan)
  assert.equal(command[0], "python3")
  assert.equal(command[1], "/home/me/.config/omarchy/plugins/x/tools/pen-buttons.py")
  assert.deepEqual(JSON.parse(command[2]), plan)
})

test("the helper script parses, self-describes, and rejects a bad plan", () => {
  const helper = path.join(__dirname, "..", "tools", "pen-buttons.py")
  assert.ok(fs.existsSync(helper))
  const usage = childProcessSync(["python3", helper, "--help"])
  assert.equal(usage.status, 64)
  assert.match(usage.stdout, /Actions: "app"/)
  const bad = childProcessSync(["python3", helper, "{not json"])
  assert.equal(bad.status, 64)
  const empty = childProcessSync(["python3", helper, JSON.stringify({ tablets: [] })])
  assert.equal(empty.status, 0)
  assert.match(empty.stderr, /nothing to do/)
})

test("the helper reaches the compositor's virtual input when run inside a Hyprland session", (t) => {
  if (!process.env.WAYLAND_DISPLAY) {
    t.skip("no Wayland session here")
    return
  }
  const helper = path.join(__dirname, "..", "tools", "pen-buttons.py")
  const check = childProcessSync(["python3", helper, "--check"])
  assert.equal(check.status, 0, check.stderr)
  assert.match(check.stdout, /virtual input ok/)
})

test("the helper turns a fake pen's buttons into the mapped actions end to end (needs /dev/uinput for the fake pen)", (t) => {
  try {
    fs.accessSync("/dev/uinput", fs.constants.W_OK)
  } catch (e) {
    t.skip("/dev/uinput is not open to this user here")
    return
  }
  const helper = path.join(__dirname, "..", "tools", "pen-buttons.py")
  const result = childProcessSync(["python3", helper, "--self-test"])
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /self-test ok/)
})

function childProcessSync(argv) {
  const childProcess = require("node:child_process")
  const result = childProcess.spawnSync(argv[0], argv.slice(1), { encoding: "utf8" })
  return { status: result.status, stdout: String(result.stdout || ""), stderr: String(result.stderr || "") }
}

test("the manifest declares both entry points and they exist", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "io.github.alxcrt.drawing-tablet")
  assert.deepEqual(manifest.kinds, ["bar-widget", "service"])
  for (const entry of Object.values(manifest.entryPoints)) {
    assert.ok(fs.existsSync(path.join(__dirname, "..", entry)), entry + " exists")
  }
})

test("kernel key capabilities say which pen switches and tools a tablet accepts", () => {
  // The One by Wacom M pen node: BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2.
  const keys = "1c03 0 0 0 0 0"
  assert.equal(Model.keyBit(keys, 0x140), true)
  assert.equal(Model.keyBit(keys, 0x141), true)
  assert.equal(Model.keyBit(keys, 0x14a), true)
  assert.equal(Model.keyBit(keys, 0x14b), true)
  assert.equal(Model.keyBit(keys, 0x14c), true)
  assert.equal(Model.keyBit(keys, 0x149), false)
  assert.equal(Model.keyBit(keys, 0x110), false)
  assert.deepEqual(Model.kernelPenCapabilities({ keys, abs: "3000003" }), { buttons: 2, eraser: true, axes: ["pressure", "distance"] })
  assert.equal(Model.kernelPenCapabilities({ keys: "" }), null)
  // Three switches, no eraser tool, pressure and tilt (a Huion-style pen).
  assert.deepEqual(Model.kernelPenCapabilities({ keys: "1a01 0 0 0 0 0", abs: "d000003" }), { buttons: 3, eraser: false, axes: ["pressure", "tilt"] })
})

test("a pen libwacom really knows is described from its stylus data, not the kernel", () => {
  const model = { styli: [
    { id: "0x802", name: "Intuos4/5 Grip Pen", axes: ["x", "y", "pressure"], buttons: 2, eraser: false, eraserType: "" },
    { id: "0x80a", name: "Intuos4/5 Grip Pen Eraser", axes: ["x", "y", "pressure"], buttons: 2, eraser: true, eraserType: "invert" }
  ] }
  assert.deepEqual(Model.penCapabilities(model, { buttons: 3, eraser: false, axes: [] }), { buttons: 2, eraserType: "invert", axes: ["x", "y", "pressure"], known: true })
  assert.equal(Model.stylusSummary({ penAxes: ["x", "y", "pressure", "tilt"], penButtons: 2, eraserType: "invert" }), "pressure · tilt · 2 buttons · eraser")
  const generic = { styli: [
    { id: "0xffffe", name: "General Pen Eraser", axes: [], buttons: 2, eraser: true, eraserType: "invert" },
    { id: "0xfffff", name: "General Pen", axes: [], buttons: 2, eraser: false, eraserType: "" }
  ] }
  assert.deepEqual(Model.penCapabilities(generic, { buttons: 2, eraser: false, axes: ["pressure"] }), { buttons: 2, eraserType: "", axes: ["pressure"], known: false })
  assert.deepEqual(Model.penCapabilities(generic, null), { buttons: 2, eraserType: "unknown", axes: [], known: false })
  assert.equal(Model.penLabel({ penButtons: 2, eraserType: "", penKnown: false }), "2 buttons · no eraser")
  assert.equal(Model.penLabel({ penButtons: 0, eraserType: "", penKnown: false, styli: [] }), "unknown to libwacom")
})

test("the plugin's own self-test pen is never listed as a tablet", () => {
  const records = Model.splitProbeSections(PROBE).devices.map(Model.parseDeviceBlock)
  const fake = { name: "Drawing Tablet for Omarchy self-test pen", uniq: "", phys: "", properties: 0, keys: "", bustype: 6, vendor: "0a11", product: "0dd2",
    props: { DEVNAME: "/dev/input/event40", ID_INPUT: "1", ID_INPUT_TABLET: "1" } }
  const tablets = Model.discoverTablets(records.concat([fake]), [], [])
  assert.deepEqual(tablets.map(t => t.kernelName), ["Wacom One by Wacom M Pen"])
})
