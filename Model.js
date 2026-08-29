// Pure, testable logic for the omarchy-drawing-tablet panel and service. Runs both as a
// QML JavaScript resource and under `node --test tests/model.test.js`, so it
// must not touch Qt, Quickshell, or the filesystem.

// ---------------------------------------------------------------- strings

// Hyprland derives an input device's config name from its kernel name by
// lowercasing it and turning spaces into dashes (deviceNameToInternalString).
// This is the name `hyprctl devices` prints and `hl.device({ name = ... })`
// expects.
function hyprlandDeviceName(kernelName) {
  return String(kernelName || "").replace(/[ \n]/g, "-").toLowerCase()
}

// Device names and monitor descriptions come from USB and EDID descriptors.
// They only ever reach Lua as quoted string data, never as code, and a name
// carrying control characters is refused outright rather than escaped.
function safeText(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (/[\u0000-\u001f\u007f]/.test(text)) return ""
  return text
}

function luaString(value) {
  var text = safeText(value)
  return '"' + text.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

function luaNumber(value) {
  var number = Number(value)
  if (!isFinite(number)) return "0"
  return String(Math.round(number * 1000) / 1000)
}

function luaBool(value) {
  return value === true ? "true" : "false"
}

function luaVec(x, y) {
  return "{" + luaNumber(x) + ", " + luaNumber(y) + "}"
}

function clamp(value, min, max) {
  var number = Number(value)
  if (!isFinite(number)) number = min
  return Math.max(min, Math.min(max, number))
}

function clone(value) {
  try {
    return JSON.parse(JSON.stringify(value))
  } catch (e) {
    return null
  }
}

// ---------------------------------------------------------------- probing

// One shell round trip gathers everything the panel and the service need to
// know: every tablet-class evdev node with its udev identity, libwacom's model
// database entry when it has one, Hyprland's own tablet list, and the monitor
// layout. Sections are delimited so a single parser turns it into a document.
function probeScript() {
  return 'for d in /sys/class/input/event*; do ' +
    '[ -e "$d" ] || continue; ' +
    'props=$(udevadm info -q property -p "$d" 2>/dev/null) || continue; ' +
    'case "$props" in *ID_INPUT_TABLET=1*|*ID_INPUT_TABLET_PAD=1*) ;; *) continue;; esac; ' +
    'printf "== device %s\\n" "$d"; ' +
    'printf "NAME=%s\\n" "$(cat "$d/device/name" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "UNIQ=%s\\n" "$(cat "$d/device/uniq" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "PHYS=%s\\n" "$(cat "$d/device/phys" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "PROPS=%s\\n" "$(cat "$d/device/properties" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "KEYS=%s\\n" "$(cat "$d/device/capabilities/key" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "ABS=%s\\n" "$(cat "$d/device/capabilities/abs" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "BUSTYPE=%s\\n" "$(cat "$d/device/id/bustype" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "VENDOR=%s\\n" "$(cat "$d/device/id/vendor" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "PRODUCT=%s\\n" "$(cat "$d/device/id/product" 2>/dev/null | tr -d "\\n")"; ' +
    'printf "%s\\n" "$props"; ' +
    'done; ' +
    'printf "== libwacom\\n"; ' +
    'command -v libwacom-list-local-devices >/dev/null 2>&1 && libwacom-list-local-devices --format=yaml 2>/dev/null; ' +
    'printf "== libwacomdb\\n"; ' +
    'grep -H -iE "^(DeviceMatch|Reversible|IntegratedIn|Buttons|NumStrips|NumRings|Class|ModelName)=" /usr/share/libwacom/*.tablet /etc/libwacom/*.tablet 2>/dev/null; ' +
    'printf "== hyprland\\n"; ' +
    'hyprctl -j devices 2>/dev/null; ' +
    'printf "\\n== monitors\\n"; ' +
    'hyprctl -j monitors 2>/dev/null; ' +
    'printf "\\n== end\\n"'
}

function probeCommand() {
  return ["sh", "-c", probeScript()]
}

function hyprctlEvalCommand(lua) {
  return ["hyprctl", "eval", String(lua || "")]
}

function hyprlandVersionCommand() {
  return ["hyprctl", "version"]
}

// Lua configuration, and with it `hyprctl eval`, arrived in Hyprland 0.55.
function hyprlandSupportsEval(versionOutput) {
  var text = String(versionOutput || "")
  var match = text.match(/Hyprland\s+v?(\d+)\.(\d+)\.(\d+)/)
  if (!match) return false
  var major = Number(match[1])
  var minor = Number(match[2])
  return major > 0 || minor >= 55
}

function splitProbeSections(text) {
  var lines = String(text || "").split("\n")
  var sections = { devices: [], libwacom: "", libwacomdb: "", uinput: "", hyprland: "", monitors: "" }
  var current = null
  var buffer = []
  function flush() {
    if (!current) return
    var body = buffer.join("\n")
    if (current.kind === "device") sections.devices.push({ sysfs: current.arg, body: body })
    else if (current.kind === "libwacom") sections.libwacom = body
    else if (current.kind === "libwacomdb") sections.libwacomdb = body
    else if (current.kind === "uinput") sections.uinput = body
    else if (current.kind === "hyprland") sections.hyprland = body
    else if (current.kind === "monitors") sections.monitors = body
    buffer = []
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var header = line.match(/^== (device|libwacom|libwacomdb|uinput|hyprland|monitors|end)(?: (.*))?$/)
    if (header) {
      flush()
      current = header[1] === "end" ? null : { kind: header[1], arg: String(header[2] || "") }
      continue
    }
    if (current) buffer.push(line)
  }
  flush()
  return sections
}

function parseDeviceBlock(block) {
  var record = { sysfs: String((block || {}).sysfs || ""), name: "", uniq: "", phys: "", properties: 0, keys: "", abs: "", bustype: 0, vendor: "", product: "", props: {} }
  var lines = String((block || {}).body || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (key === "NAME") record.name = value
    else if (key === "UNIQ") record.uniq = value
    else if (key === "PHYS") record.phys = value
    else if (key === "PROPS") record.properties = parseInt(value.trim(), 16) || 0
    else if (key === "KEYS") record.keys = value.trim()
    else if (key === "ABS") record.abs = value.trim()
    else if (key === "BUSTYPE") record.bustype = parseInt(value.trim(), 16) || 0
    else if (key === "VENDOR") record.vendor = value.trim().toLowerCase()
    else if (key === "PRODUCT") record.product = value.trim().toLowerCase()
    else record.props[key] = value
  }
  return record
}

// The kernel's INPUT_PROP_DIRECT: the pen touches the picture it points at,
// i.e. a display tablet. libinput only honours a calibration matrix (which is
// how Hyprland rotates a tablet) on such devices.
var INPUT_PROP_DIRECT = 0x02

// libwacom's database entries, keyed by the bus:vid:pid triple. Only the
// fields that decide what a tablet can do are read: whether it is built into
// a screen (rotatable), whether it may be turned around (left-handed), and
// what its pad carries.
function parseLibwacomDb(text) {
  var files = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^([^:]+\.tablet):([A-Za-z]+)=(.*)$/)
    if (!match) continue
    var file = match[1]
    var key = match[2].toLowerCase()
    var value = match[3].trim()
    var entry = files[file]
    if (!entry) {
      entry = { file: file, matches: [], modelName: "", className: "", reversible: false, integratedIn: "", buttons: 0, rings: 0, strips: 0 }
      files[file] = entry
    }
    if (key === "devicematch") {
      var parts = value.split(";")
      for (var p = 0; p < parts.length; p++) {
        var fields = parts[p].trim().toLowerCase().split("|")
        if (fields.length >= 3 && fields[0] !== "" && fields[0] !== "generic") entry.matches.push(fields[0] + ":" + fields[1] + ":" + fields[2])
      }
    } else if (key === "modelname") entry.modelName = value
    else if (key === "class") entry.className = value
    else if (key === "reversible") entry.reversible = value.toLowerCase() === "true"
    else if (key === "integratedin") entry.integratedIn = value
    else if (key === "buttons") entry.buttons = parseInt(value, 10) || 0
    else if (key === "numrings") entry.rings = parseInt(value, 10) || 0
    else if (key === "numstrips") entry.strips = parseInt(value, 10) || 0
  }
  var byMatch = {}
  for (var name in files) {
    var item = files[name]
    for (var m = 0; m < item.matches.length; m++) if (!byMatch[item.matches[m]]) byMatch[item.matches[m]] = item
  }
  return byMatch
}

function libwacomEntryFor(db, bus, vendorId, productId) {
  var key = String(bus || "").toLowerCase() + ":" + String(vendorId || "").toLowerCase() + ":" + String(productId || "").toLowerCase()
  return db && db[key] ? db[key] : null
}

// libwacom's yaml is small and regular enough to read line by line: a device
// starts at "  - name:", its nodes and styli are nested lists. Anything the
// reader does not understand is skipped rather than failing the whole probe.
function parseLibwacomYaml(text) {
  var devices = []
  var device = null
  var list = ""
  var stylus = null
  var lines = String(text || "").split("\n")

  function unquote(value) {
    var trimmed = String(value || "").trim()
    var match = trimmed.match(/^'(.*)'$/) || trimmed.match(/^"(.*)"$/)
    return match ? match[1] : trimmed
  }

  function parseAxes(value) {
    var inner = String(value || "").replace(/^\s*\[/, "").replace(/\]\s*$/, "")
    return inner.split(",").map(function(item) { return unquote(item) }).filter(function(item) { return item !== "" })
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var deviceStart = line.match(/^  - name:\s*(.*)$/)
    if (deviceStart) {
      device = { name: unquote(deviceStart[1]), bus: "", vid: "", pid: "", nodes: [], styli: [] }
      devices.push(device)
      list = ""
      stylus = null
      continue
    }
    if (!device) continue
    var field = line.match(/^    ([a-z_]+):\s*(.*)$/)
    if (field) {
      list = ""
      stylus = null
      var key = field[1]
      var value = field[2]
      if (key === "nodes") list = "nodes"
      else if (key === "styli") list = "styli"
      else if (key === "bus") device.bus = unquote(value)
      else if (key === "vid") device.vid = unquote(value).replace(/^0x/i, "").toLowerCase()
      else if (key === "pid") device.pid = unquote(value).replace(/^0x/i, "").toLowerCase()
      continue
    }
    if (list === "nodes") {
      var node = line.match(/^      - (\/dev\/input\/\S+):\s*(.*)$/)
      if (node) device.nodes.push({ path: node[1], name: unquote(node[2]) })
      continue
    }
    if (list === "styli") {
      var stylusStart = line.match(/^      - id:\s*(.*)$/)
      if (stylusStart) {
        stylus = { id: unquote(stylusStart[1]), name: "", axes: [], buttons: 0, eraser: false, eraserType: "" }
        device.styli.push(stylus)
        continue
      }
      var stylusField = line.match(/^        ([a-z_]+):\s*(.*)$/)
      if (stylus && stylusField) {
        var stylusKey = stylusField[1]
        var stylusValue = stylusField[2]
        if (stylusKey === "name") stylus.name = unquote(stylusValue)
        else if (stylusKey === "axes") stylus.axes = parseAxes(stylusValue)
        else if (stylusKey === "buttons") stylus.buttons = Number(stylusValue) || 0
        else if (stylusKey === "is_eraser") stylus.eraser = unquote(stylusValue) === "true"
        else if (stylusKey === "eraser_type") stylus.eraserType = unquote(stylusValue).toLowerCase()
      }
    }
  }
  return devices
}

function parseHyprlandTabletNames(json) {
  try {
    var value = JSON.parse(String(json || ""))
    var tablets = value && value.tablets instanceof Array ? value.tablets : []
    return tablets.map(function(tablet) { return String((tablet || {}).name || "") }).filter(function(name) { return name !== "" })
  } catch (e) {
    return []
  }
}

// Hyprland reports each monitor's mode in physical pixels. Tablet regions are
// expressed in the logical layout, so scale and rotation are folded in here
// once and every later computation works in logical pixels.
function parseMonitors(json) {
  var list
  try {
    list = JSON.parse(String(json || ""))
  } catch (e) {
    return []
  }
  if (!(list instanceof Array)) return []
  var boxes = []
  for (var i = 0; i < list.length; i++) {
    var monitor = list[i] || {}
    if (monitor.disabled === true) continue
    var scale = Number(monitor.scale || 1)
    if (!isFinite(scale) || scale <= 0) scale = 1
    var width = Math.max(1, Math.round(Number(monitor.width || 0) / scale))
    var height = Math.max(1, Math.round(Number(monitor.height || 0) / scale))
    var transform = Number(monitor.transform || 0)
    if (transform % 2 === 1) {
      var swap = width
      width = height
      height = swap
    }
    boxes.push({
      name: safeText(monitor.name),
      description: safeText(monitor.description),
      x: Math.round(Number(monitor.x || 0)),
      y: Math.round(Number(monitor.y || 0)),
      width: width,
      height: height,
      scale: scale,
      transform: transform,
      focused: monitor.focused === true
    })
  }
  return boxes
}

// Bus names as libwacom's DeviceMatch spells them (input.h BUS_* values).
function busName(bustype, fallback) {
  switch (Number(bustype || 0)) {
    case 0x03: return "usb"
    case 0x05: return "bluetooth"
    case 0x18: return "i2c"
    case 0x06: return "virtual"
    case 0x01: return "pci"
    default: return String(fallback || "").toLowerCase()
  }
}

// The kernel's own vendor/product ids: udev only fills ID_VENDOR_ID for USB,
// so a Bluetooth or uinput tablet would otherwise have no identity at all.
function deviceIds(record) {
  var item = record || {}
  var props = item.props || {}
  var vendor = String(item.vendor || props.ID_VENDOR_ID || "").toLowerCase().replace(/^0+(?=.)/, "")
  var product = String(item.product || props.ID_MODEL_ID || "").toLowerCase().replace(/^0+(?=.)/, "")
  function pad(value) { return value === "" || value === "0" ? "" : ("0000" + value).slice(-4) }
  return {
    bus: busName(item.bustype, props.ID_BUS) || "unknown",
    vendor: pad(vendor),
    product: pad(product),
    serial: safeText(props.ID_SERIAL_SHORT || item.uniq || "").trim()
  }
}

function tabletIdentity(record) {
  var ids = deviceIds(record)
  if (ids.vendor === "" && ids.product === "") {
    return ids.bus + ":" + hyprlandDeviceName((record || {}).name) + (ids.serial !== "" ? ":" + ids.serial : "")
  }
  return ids.bus + ":" + ids.vendor + ":" + ids.product + (ids.serial !== "" ? ":" + ids.serial : "")
}

function vendorLabel(props) {
  var vendor = String((props || {}).ID_VENDOR_ENC || (props || {}).ID_VENDOR || "")
  vendor = vendor.replace(/\\x([0-9a-fA-F]{2})/g, function(match, hex) { return String.fromCharCode(parseInt(hex, 16)) })
  return safeText(vendor.replace(/_/g, " ").trim())
}

// Turns the raw probe into the list of tablets the panel shows. A tablet is
// the pen device; a matching pad only marks that the tablet has buttons.
//
// What libinput will let Hyprland do with the tablet is decided here, from
// the same facts libinput itself uses (evdev-tablet.c): a calibration matrix,
// hence any rotation, only for tablets built into a screen or unknown to
// libwacom; the 180° left-handed flip only for tablets libwacom marks as
// reversible, or unknown ones.
// evdev key codes the kernel advertises for a pen: which side switches the
// tablet understands and whether it can report an eraser tool at all.
var BTN_TOOL_RUBBER = 0x141
var BTN_STYLUS3 = 0x149
var BTN_STYLUS = 0x14b
var BTN_STYLUS2 = 0x14c
var ABS_PRESSURE = 0x18
var ABS_DISTANCE = 0x19
var ABS_TILT_X = 0x1a
var ABS_TILT_Y = 0x1b

// sysfs capabilities/key: space-separated hex words, highest word first, 64
// bits each on the kernels Omarchy runs on.
function keyBit(keys, code) {
  var words = String(keys || "").trim().split(/\s+/).filter(function(word) { return word !== "" })
  var wordIndex = Math.floor(code / 64)
  var word = words[words.length - 1 - wordIndex]
  if (!word) return false
  var bit = code % 64
  var digit = word.charAt(word.length - 1 - Math.floor(bit / 4))
  if (digit === "") return false
  return ((parseInt(digit, 16) >> (bit % 4)) & 1) === 1
}

function kernelPenCapabilities(record) {
  var keys = String((record || {}).keys || "")
  if (keys === "") return null
  var buttons = 0
  if (keyBit(keys, BTN_STYLUS)) buttons++
  if (keyBit(keys, BTN_STYLUS2)) buttons++
  if (keyBit(keys, BTN_STYLUS3)) buttons++
  var abs = String((record || {}).abs || "")
  var axes = []
  if (keyBit(abs, ABS_PRESSURE)) axes.push("pressure")
  if (keyBit(abs, ABS_TILT_X) && keyBit(abs, ABS_TILT_Y)) axes.push("tilt")
  if (keyBit(abs, ABS_DISTANCE)) axes.push("distance")
  return { buttons: buttons, eraser: keyBit(keys, BTN_TOOL_RUBBER), axes: axes }
}

// libwacom's placeholders for a pen it has no data on.
var LIBWACOM_FALLBACK_STYLI = ["0xfffff", "0xffffe"]

function discoverTablets(records, libwacomDevices, hyprlandNames, libwacomDb) {
  var pens = []
  var pads = []
  var list = records instanceof Array ? records : []
  for (var i = 0; i < list.length; i++) {
    var record = list[i] || {}
    var props = record.props || {}
    // A node libinput is told to ignore (OpenTabletDriver does this to the
    // kernel device it replaces) is not a tablet Hyprland will ever see.
    if (props.LIBINPUT_IGNORE_DEVICE === "1") continue
    // The plugin's own virtual devices (the self-test pen) are not tablets to map.
    if (/^Drawing Tablet for Omarchy /.test(String(record.name || ""))) continue
    if (props.ID_INPUT_TABLET_PAD === "1") pads.push(record)
    else if (props.ID_INPUT_TABLET === "1" && props.ID_INPUT_TOUCHSCREEN !== "1" && props.ID_INPUT_TOUCHPAD !== "1") pens.push(record)
  }
  var byId = {}
  var tablets = []
  var models = libwacomDevices instanceof Array ? libwacomDevices : []
  var names = hyprlandNames instanceof Array ? hyprlandNames : []
  for (var p = 0; p < pens.length; p++) {
    var pen = pens[p]
    var id = tabletIdentity(pen)
    if (byId[id]) continue
    var node = String((pen.props || {}).DEVNAME || "")
    var model = null
    for (var m = 0; m < models.length; m++) {
      var candidate = models[m] || {}
      var nodes = candidate.nodes instanceof Array ? candidate.nodes : []
      for (var n = 0; n < nodes.length; n++) {
        if (String((nodes[n] || {}).path || "") === node) model = candidate
      }
    }
    var kernelName = safeText(pen.name)
    var hyprlandName = hyprlandDeviceName(kernelName)
    var ids = deviceIds(pen)
    var bus = model && model.bus ? String(model.bus) : ids.bus
    var vendorId = model && model.vid ? String(model.vid) : ids.vendor
    var productId = model && model.pid ? String(model.pid) : ids.product
    var entry = libwacomEntryFor(libwacomDb, bus, vendorId, productId) || libwacomEntryFor(libwacomDb, ids.bus, ids.vendor, ids.product)
    var direct = (Number(pen.properties || 0) & INPUT_PROP_DIRECT) !== 0
    var integratedIn = entry ? String(entry.integratedIn || "") : ""
    var integrated = integratedIn !== ""
    var penCaps = penCapabilities(model, kernelPenCapabilities(pen))
    var tablet = {
      id: id,
      label: (model ? safeText(model.name) : "") || kernelName,
      vendor: vendorLabel(pen.props),
      kernelName: kernelName,
      hyprlandName: hyprlandName,
      present: names.indexOf(hyprlandName) !== -1,
      node: node,
      bus: bus,
      vendorId: vendorId,
      productId: productId,
      serial: ids.serial,
      widthMm: Number((pen.props || {}).ID_INPUT_WIDTH_MM || 0) || 0,
      heightMm: Number((pen.props || {}).ID_INPUT_HEIGHT_MM || 0) || 0,
      hasPad: false,
      known: !!entry,
      display: direct || integrated,
      integratedIn: integratedIn,
      rotatable: direct || integrated || !entry,
      reversible: !entry || entry.reversible === true,
      penButtons: penCaps.buttons,
      eraserType: penCaps.eraserType,
      penKnown: penCaps.known,
      penAxes: penCaps.axes,
      padButtons: entry ? Number(entry.buttons || 0) : 0,
      rings: entry ? Number(entry.rings || 0) : 0,
      strips: entry ? Number(entry.strips || 0) : 0,
      styli: model && model.styli instanceof Array ? model.styli : []
    }
    byId[id] = tablet
    tablets.push(tablet)
  }
  for (var q = 0; q < pads.length; q++) {
    var padId = tabletIdentity(pads[q])
    if (byId[padId]) byId[padId].hasPad = true
  }
  tablets.sort(function(a, b) { return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0) })
  return tablets
}

// What libwacom says about the pen: how many side buttons it has and what
// kind of eraser, if any. libinput's eraser-button setting only applies to a
// pen whose eraser is a button, not one on the back end.
function penCapabilities(model, kernel) {
  var styli = model && model.styli instanceof Array ? model.styli : []
  var real = styli.filter(function(stylus) {
    return LIBWACOM_FALLBACK_STYLI.indexOf(String((stylus || {}).id || "").toLowerCase()) === -1
  })
  if (real.length === 0) {
    // libwacom only offered its generic pen and eraser: it does not know this
    // pen, so the kernel's word on what the tablet accepts is all there is.
    var caps = kernel || null
    if (!caps) {
      var fallbackButtons = 0
      for (var f = 0; f < styli.length; f++) if (!(styli[f] || {}).eraser) fallbackButtons = Math.max(fallbackButtons, Number((styli[f] || {}).buttons || 0))
      caps = { buttons: fallbackButtons, eraser: styli.length > 0, axes: [] }
    }
    return { buttons: caps.buttons, eraserType: caps.eraser ? "unknown" : "", axes: caps.axes || [], known: false }
  }
  var buttons = 0
  var eraserType = ""
  var axes = []
  for (var i = 0; i < real.length; i++) {
    var stylus = real[i] || {}
    if (!stylus.eraser) {
      buttons = Math.max(buttons, Number(stylus.buttons || 0))
      var list = stylus.axes instanceof Array ? stylus.axes : []
      for (var a = 0; a < list.length; a++) if (axes.indexOf(list[a]) === -1) axes.push(list[a])
    }
    var type = String(stylus.eraserType || "")
    if (type !== "" && type !== "none" && eraserType === "") eraserType = type
  }
  return { buttons: buttons, eraserType: eraserType, axes: axes, known: true }
}

function penLabel(tablet) {
  var item = tablet || {}
  var buttons = Number(item.penButtons || 0)
  var parts = []
  if (item.penKnown !== true && buttons === 0 && String(item.eraserType || "") === "") return "unknown to libwacom"
  parts.push(buttons > 0 ? buttons + (buttons === 1 ? " button" : " buttons") : "no buttons")
  if (item.eraserType === "invert") parts.push("eraser on the back end")
  else if (item.eraserType === "button") parts.push("eraser button")
  else if (item.eraserType === "unknown") parts.push("eraser if the pen has one")
  else parts.push("no eraser")
  return parts.join(" · ")
}

function anyEraserButton(tablets) {
  var list = tablets instanceof Array ? tablets : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].eraserType === "button") return true
  return false
}

function parseProbe(text) {
  var sections = splitProbeSections(text)
  var records = sections.devices.map(parseDeviceBlock)
  var libwacom = parseLibwacomYaml(sections.libwacom)
  var libwacomDb = parseLibwacomDb(sections.libwacomdb)
  var hyprlandNames = parseHyprlandTabletNames(sections.hyprland)
  return {
    tablets: discoverTablets(records, libwacom, hyprlandNames, libwacomDb),
    monitors: parseMonitors(sections.monitors),
    hyprlandNames: hyprlandNames
  }
}

function stylusSummary(tablet) {
  // What the pen reports: libwacom's stylus data when it knows the pen, the
  // kernel's axes and switches when it does not.
  var item = tablet || {}
  var axes = item.penAxes instanceof Array ? item.penAxes : []
  var parts = []
  if (axes.indexOf("pressure") !== -1) parts.push("pressure")
  if (axes.indexOf("tilt") !== -1) parts.push("tilt")
  if (axes.indexOf("rotation") !== -1) parts.push("rotation")
  var buttons = Number(item.penButtons || 0)
  if (buttons > 0) parts.push(buttons + (buttons === 1 ? " button" : " buttons"))
  if (item.eraserType === "invert" || item.eraserType === "button") parts.push("eraser")
  return parts.join(" · ")
}

function tabletSizeLabel(tablet) {
  var width = Number((tablet || {}).widthMm || 0)
  var height = Number((tablet || {}).heightMm || 0)
  if (width <= 0 || height <= 0) return "size unknown"
  return Math.round(width) + " × " + Math.round(height) + " mm"
}

// ---------------------------------------------------------------- document

var DOCUMENT_VERSION = 1

function defaultStylus() {
  return {
    pressureRangeEnabled: false,
    pressureMin: 0,
    pressureMax: 1,
    eraserButtonMode: 0,
    eraserButtonOverride: 0,
    hideCursor: false
  }
}

function defaultProfile(tablet) {
  var item = tablet || {}
  return {
    id: String(item.id || ""),
    label: safeText(item.label || item.kernelName || "Tablet") || "Tablet",
    kernelName: safeText(item.kernelName || ""),
    widthMm: Number(item.widthMm || 0) || 0,
    heightMm: Number(item.heightMm || 0) || 0,
    output: { mode: "layout", name: "", description: "" },
    region: { mode: "full", x: 0, y: 0, w: 1, h: 1 },
    activeArea: { mode: "full", x: 0, y: 0, w: 0, h: 0 },
    transform: 0,
    leftHanded: false,
    relativeInput: false,
    rotatable: item.rotatable !== false,
    reversible: item.reversible !== false,
    buttons: { button1: "app", button2: "app", eraser: "app" }
  }
}

var BUTTON_ACTIONS = ["app", "left", "middle", "right", "space", "scroll"]

function normalizeButtons(raw) {
  var item = raw && typeof raw === "object" ? raw : {}
  return {
    button1: normalizeMode(item.button1, BUTTON_ACTIONS, "app"),
    button2: normalizeMode(item.button2, BUTTON_ACTIONS, "app"),
    eraser: normalizeMode(item.eraser, BUTTON_ACTIONS, "app")
  }
}

// The transform Hyprland will actually get: libinput ignores the calibration
// matrix on an external tablet, so pretending otherwise would also miscompute
// the active area for it.
function effectiveTransform(profile) {
  var item = profile || {}
  if (item.rotatable === false) return 0
  return clamp(Math.round(Number(item.transform)), 0, 7)
}

function normalizeMode(value, allowed, fallback) {
  var mode = String(value || "")
  return allowed.indexOf(mode) !== -1 ? mode : fallback
}

function normalizeProfile(raw, tablet) {
  var base = defaultProfile(tablet)
  var item = raw && typeof raw === "object" ? raw : {}
  var profile = base
  profile.id = String(item.id || base.id || "")
  profile.label = safeText(item.label) || base.label
  profile.kernelName = safeText(item.kernelName) || base.kernelName
  profile.widthMm = Number(item.widthMm || 0) > 0 ? Number(item.widthMm) : base.widthMm
  profile.heightMm = Number(item.heightMm || 0) > 0 ? Number(item.heightMm) : base.heightMm
  var output = item.output && typeof item.output === "object" ? item.output : {}
  profile.output = {
    mode: normalizeMode(output.mode, ["layout", "current", "monitor"], "layout"),
    name: safeText(output.name),
    description: safeText(output.description)
  }
  if (profile.output.mode === "monitor" && profile.output.name === "" && profile.output.description === "") profile.output.mode = "layout"
  var region = item.region && typeof item.region === "object" ? item.region : {}
  profile.region = clampRegion({
    mode: normalizeMode(region.mode, ["full", "aspect", "custom"], "full"),
    x: region.x, y: region.y, w: region.w, h: region.h
  })
  var area = item.activeArea && typeof item.activeArea === "object" ? item.activeArea : {}
  profile.activeArea = {
    mode: normalizeMode(area.mode, ["full", "aspect", "custom"], "full"),
    x: Math.max(0, Number(area.x) || 0),
    y: Math.max(0, Number(area.y) || 0),
    w: Math.max(0, Number(area.w) || 0),
    h: Math.max(0, Number(area.h) || 0)
  }
  profile.transform = clamp(Math.round(Number(item.transform)), 0, 7)
  profile.leftHanded = item.leftHanded === true
  profile.relativeInput = item.relativeInput === true
  profile.rotatable = item.rotatable !== false
  profile.reversible = item.reversible !== false
  profile.buttons = normalizeButtons(item.buttons)
  return profile
}

// Custom regions are fractions of the target box so they survive a scale or
// resolution change. Keep them inside the box and at least a sliver wide.
function clampRegion(region) {
  var item = region || {}
  function given(value) {
    return value !== undefined && value !== null && isFinite(Number(value))
  }
  var w = given(item.w) ? clamp(item.w, 0.05, 1) : 1
  var h = given(item.h) ? clamp(item.h, 0.05, 1) : 1
  var x = given(item.x) ? clamp(item.x, 0, 1 - w) : 0
  var y = given(item.y) ? clamp(item.y, 0, 1 - h) : 0
  return {
    mode: normalizeMode(item.mode, ["full", "aspect", "custom"], "full"),
    x: Math.round(x * 10000) / 10000,
    y: Math.round(y * 10000) / 10000,
    w: Math.round(w * 10000) / 10000,
    h: Math.round(h * 10000) / 10000
  }
}

// Hyprland's eraser override is an evdev button code. Anything outside the
// button range is not a button and is dropped back to "default".
function normalizeStylus(raw) {
  var base = defaultStylus()
  var item = raw && typeof raw === "object" ? raw : {}
  // libinput insists on 0 <= min < max <= 1; keep a sliver between them so a
  // slider dragged past the other one cannot produce a window of zero width.
  var min = clamp(item.pressureMin === undefined ? base.pressureMin : item.pressureMin, 0, 0.95)
  var max = clamp(item.pressureMax === undefined ? base.pressureMax : item.pressureMax, 0.05, 1)
  if (max < min + 0.05) max = Math.min(1, min + 0.05)
  if (max < min + 0.05) min = Math.max(0, max - 0.05)
  var override = Math.round(Number(item.eraserButtonOverride))
  if (!isFinite(override) || override < 0x100 || override > 0x2ff) override = 0
  return {
    pressureRangeEnabled: item.pressureRangeEnabled === true,
    pressureMin: Math.round(min * 100) / 100,
    pressureMax: Math.round(max * 100) / 100,
    eraserButtonMode: clamp(Math.round(Number(item.eraserButtonMode)), 0, 1),
    eraserButtonOverride: override,
    hideCursor: item.hideCursor === true
  }
}

function normalizeDocument(raw) {
  var item = raw && typeof raw === "object" ? raw : {}
  var tablets = item.tablets instanceof Array ? item.tablets : []
  var seen = {}
  var profiles = []
  for (var i = 0; i < tablets.length; i++) {
    var profile = normalizeProfile(tablets[i], null)
    if (profile.id === "" || seen[profile.id]) continue
    seen[profile.id] = true
    profiles.push(profile)
  }
  return { version: DOCUMENT_VERSION, stylus: normalizeStylus(item.stylus), tablets: profiles }
}

function parseDocument(text) {
  var raw = null
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    raw = null
  }
  return normalizeDocument(raw)
}

function serializeDocument(document) {
  return JSON.stringify(normalizeDocument(document), null, 2) + "\n"
}

function documentPath(home) {
  return String(home || "") + "/.config/omarchy-drawing-tablet/tablets.json"
}

// Writing goes through argv, never a shell-interpolated string: the JSON is
// $2, the path is $1, and the rename makes the update atomic.
function saveCommand(path, text) {
  return [
    "sh",
    "-c",
    'set -e; dir=$(dirname -- "$1"); mkdir -p -- "$dir"; tmp="$1.tmp.$$"; printf "%s" "$2" > "$tmp"; mv -f -- "$tmp" "$1"',
    "sh",
    String(path || ""),
    String(text || "")
  ]
}

function profileById(document, id) {
  var tablets = document && document.tablets instanceof Array ? document.tablets : []
  for (var i = 0; i < tablets.length; i++) {
    if (String((tablets[i] || {}).id || "") === String(id || "")) return tablets[i]
  }
  return null
}

function upsertProfile(document, profile) {
  var next = normalizeDocument(document)
  var normalized = normalizeProfile(profile, null)
  var replaced = false
  for (var i = 0; i < next.tablets.length; i++) {
    if (next.tablets[i].id === normalized.id) {
      next.tablets[i] = normalized
      replaced = true
    }
  }
  if (!replaced && normalized.id !== "") next.tablets.push(normalized)
  return next
}

function removeProfile(document, id) {
  var next = normalizeDocument(document)
  next.tablets = next.tablets.filter(function(profile) { return profile.id !== String(id || "") })
  return next
}

// A tablet seen for the first time gets a default profile so the panel has
// something to edit. Physical size is refreshed from the live device, since
// the kernel knows it better than a stale profile does.
function mergeDiscovered(document, tablets, monitors) {
  var next = normalizeDocument(document)
  var before = JSON.stringify(next)
  var list = tablets instanceof Array ? tablets : []
  var added = 0
  var internal = internalMonitor(monitors)
  for (var i = 0; i < list.length; i++) {
    var tablet = list[i] || {}
    if (String(tablet.id || "") === "") continue
    var existing = profileById(next, tablet.id)
    if (existing) {
      if (Number(tablet.widthMm || 0) > 0) existing.widthMm = Number(tablet.widthMm)
      if (Number(tablet.heightMm || 0) > 0) existing.heightMm = Number(tablet.heightMm)
      if (existing.kernelName === "") existing.kernelName = safeText(tablet.kernelName)
      if (existing.label === "" || existing.label === "Tablet") existing.label = safeText(tablet.label) || existing.label
      existing.rotatable = tablet.rotatable !== false
      existing.reversible = tablet.reversible !== false
      // A rotation the hardware cannot do is not worth remembering: it would
      // only keep the summary claiming something the pen does not show.
      if (!existing.rotatable && existing.transform !== 0) existing.transform = 0
      if (!existing.reversible && existing.leftHanded) existing.leftHanded = false
    } else {
      var fresh = defaultProfile(tablet)
      // A digitizer built into the laptop belongs on the laptop's own panel;
      // nothing else about a new tablet can be guessed better than Hyprland's
      // own default of the whole layout.
      if (internal && /System/i.test(String(tablet.integratedIn || ""))) {
        fresh.output = { mode: "monitor", name: String(internal.name || ""), description: String(internal.description || "") }
      }
      next.tablets.push(fresh)
      added++
    }
  }
  // Anything the hardware corrected (size, capabilities, a rotation it cannot
  // do) must reach the disk too, or the next reload brings the stale version
  // back and the panel flickers between the two.
  return { document: next, added: added, changed: JSON.stringify(next) !== before }
}

function internalMonitor(boxes) {
  var list = boxes instanceof Array ? boxes : []
  for (var i = 0; i < list.length; i++) {
    if (/^(eDP|LVDS|DSI)-/i.test(String((list[i] || {}).name || ""))) return list[i]
  }
  return null
}

// ---------------------------------------------------------------- geometry

function layoutBounds(boxes) {
  var list = boxes || []
  if (list.length === 0) return { x: 0, y: 0, width: 1, height: 1 }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (var i = 0; i < list.length; i++) {
    var box = list[i] || {}
    var x = Number(box.x || 0)
    var y = Number(box.y || 0)
    var width = Math.max(1, Number(box.width || 1))
    var height = Math.max(1, Number(box.height || 1))
    minX = Math.min(minX, x)
    minY = Math.min(minY, y)
    maxX = Math.max(maxX, x + width)
    maxY = Math.max(maxY, y + height)
  }
  return { x: minX, y: minY, width: Math.max(1, maxX - minX), height: Math.max(1, maxY - minY) }
}

function transformSwapsAxes(transform) {
  return Math.abs(Math.round(Number(transform || 0))) % 2 === 1
}

// The tablet as libinput sees it after the calibration matrix: a 90° or 270°
// transform swaps its axes, and the active area is expressed in that space.
function effectiveTabletSize(profile) {
  var width = Number((profile || {}).widthMm || 0)
  var height = Number((profile || {}).heightMm || 0)
  if (transformSwapsAxes(effectiveTransform(profile))) return { width: height, height: width }
  return { width: width, height: height }
}

function findMonitor(boxes, name, description) {
  var list = boxes || []
  var wantedDescription = String(description || "")
  var wantedName = String(name || "")
  if (wantedDescription !== "") {
    for (var i = 0; i < list.length; i++) {
      if (String((list[i] || {}).description || "") === wantedDescription) return list[i]
    }
  }
  if (wantedName !== "") {
    for (var j = 0; j < list.length; j++) {
      if (String((list[j] || {}).name || "") === wantedName) return list[j]
    }
  }
  return null
}

// Resolves where the tablet lands. Hyprland accepts a monitor by connector
// or by `desc:`; the description is preferred so the mapping follows the
// screen to another port. A screen that is not connected falls back to the
// whole layout rather than to nothing.
function outputTarget(profile, boxes) {
  var output = (profile || {}).output || {}
  var list = boxes || []
  if (output.mode === "current") {
    return { kind: "current", value: "current", box: null, missing: false }
  }
  if (output.mode === "monitor") {
    var monitor = findMonitor(list, output.name, output.description)
    if (monitor) {
      var value = String(monitor.description || "") !== "" ? "desc:" + monitor.description : String(monitor.name || "")
      return { kind: "monitor", value: value, box: monitor, missing: false }
    }
    return { kind: "layout", value: "", box: layoutBounds(list), missing: true }
  }
  return { kind: "layout", value: "", box: layoutBounds(list), missing: false }
}

// Largest box with the wanted proportions that fits inside the container,
// centred. Returns fractions of the container so callers can scale it to
// pixels or millimetres alike.
function fitAspect(containerWidth, containerHeight, aspectWidth, aspectHeight) {
  var cw = Number(containerWidth || 0)
  var ch = Number(containerHeight || 0)
  var aw = Number(aspectWidth || 0)
  var ah = Number(aspectHeight || 0)
  if (cw <= 0 || ch <= 0 || aw <= 0 || ah <= 0) return { x: 0, y: 0, w: 1, h: 1 }
  var containerRatio = cw / ch
  var wantedRatio = aw / ah
  if (wantedRatio >= containerRatio) {
    var h = containerRatio / wantedRatio
    return { x: 0, y: (1 - h) / 2, w: 1, h: h }
  }
  var w = wantedRatio / containerRatio
  return { x: (1 - w) / 2, y: 0, w: w, h: 1 }
}

// Region fractions of the target box for the profile's region mode. `full`
// and anything without a measurable box return null, meaning "leave it to
// Hyprland", which maps the whole box.
function regionFractions(profile, box) {
  var region = (profile || {}).region || {}
  if (!box) return null
  if (region.mode === "custom") return clampRegion(region)
  if (region.mode === "aspect") {
    var size = effectiveTabletSize(profile)
    if (size.width <= 0 || size.height <= 0) return null
    var fit = fitAspect(box.width, box.height, size.width, size.height)
    return { mode: "aspect", x: fit.x, y: fit.y, w: fit.w, h: fit.h }
  }
  return null
}

function regionPixels(profile, box) {
  var fractions = regionFractions(profile, box)
  if (!fractions || !box) return null
  var w = Math.max(1, Math.round(box.width * fractions.w))
  var h = Math.max(1, Math.round(box.height * fractions.h))
  var x = Math.round(box.width * fractions.x)
  var y = Math.round(box.height * fractions.y)
  if (x + w > box.width) x = Math.max(0, box.width - w)
  if (y + h > box.height) y = Math.max(0, box.height - h)
  return { x: x, y: y, w: w, h: h }
}

function round1(value) {
  return Math.round(Number(value || 0) * 10) / 10
}

// Active area in millimetres of the (transformed) tablet surface. `aspect`
// crops the tablet to the target's proportions so a pen millimetre is the
// same distance on screen in both directions.
function activeAreaMm(profile, box) {
  var area = (profile || {}).activeArea || {}
  var size = effectiveTabletSize(profile)
  if (size.width <= 0 || size.height <= 0) return null
  if (area.mode === "custom") {
    var w = clamp(area.w, 1, size.width)
    var h = clamp(area.h, 1, size.height)
    var x = clamp(area.x, 0, size.width - w)
    var y = clamp(area.y, 0, size.height - h)
    return { x: round1(x), y: round1(y), w: round1(w), h: round1(h) }
  }
  if (area.mode === "aspect") {
    if (!box) return null
    var regionPx = regionPixels(profile, box)
    var targetWidth = regionPx ? regionPx.w : box.width
    var targetHeight = regionPx ? regionPx.h : box.height
    var fit = fitAspect(size.width, size.height, targetWidth, targetHeight)
    return {
      x: round1(fit.x * size.width),
      y: round1(fit.y * size.height),
      w: round1(fit.w * size.width),
      h: round1(fit.h * size.height)
    }
  }
  return null
}

// The `hl.device` statement for one tablet. Every field is emitted, including
// the zero vectors, so an earlier custom mapping is cleared instead of
// lingering in Hyprland's per-device state.
function deviceStatement(profile, boxes) {
  var item = profile || {}
  var name = safeText(item.kernelName)
  if (name === "") return null
  var notes = []
  var fields = ["name = " + luaString(hyprlandDeviceName(name))]
  var target = outputTarget(item, boxes)
  if (target.missing) {
    notes.push(String(item.label || "Tablet") + ": " + describeOutput(item, boxes) + " is not connected, so it is mapped to all screens for now")
  }
  var region = regionPixels(item, target.box)
  var area = activeAreaMm(item, target.box)
  fields.push("output = " + luaString(target.value))
  fields.push("transform = " + luaNumber(effectiveTransform(item)))
  fields.push("left_handed = " + luaBool(item.leftHanded === true && item.reversible !== false))
  fields.push("relative_input = " + luaBool(item.relativeInput === true))
  fields.push("absolute_region_position = false")
  fields.push("region_position = " + (region ? luaVec(region.x, region.y) : luaVec(0, 0)))
  fields.push("region_size = " + (region ? luaVec(region.w, region.h) : luaVec(0, 0)))
  fields.push("active_area_position = " + (area ? luaVec(area.x, area.y) : luaVec(0, 0)))
  fields.push("active_area_size = " + (area ? luaVec(area.w, area.h) : luaVec(0, 0)))
  return { lua: "hl.device({ " + fields.join(", ") + " })", notes: notes }
}

// Hyprland's stylus settings are global. A negative pressure bound means
// "use the tool's own default", which is what the toggle turns back on.
function stylusStatement(stylus) {
  var item = normalizeStylus(stylus)
  var min = item.pressureRangeEnabled ? item.pressureMin : -1
  var max = item.pressureRangeEnabled ? item.pressureMax : -1
  return "hl.config({ input = { tablettool = { pressure_range_min = " + luaNumber(min)
    + ", pressure_range_max = " + luaNumber(max)
    + ", eraser_button_mode = " + luaNumber(item.eraserButtonMode)
    + ", eraser_button_override = " + luaNumber(item.eraserButtonOverride) + " } } })"
}

// Hyprland can hide the pointer while the pen is in use (cursor:hide_on_tablet).
function cursorStatement(stylus) {
  var item = normalizeStylus(stylus)
  return "hl.config({ cursor = { hide_on_tablet = " + luaBool(item.hideCursor) + " } })"
}

// Everything to run, in order, for the current hardware. Only tablets Hyprland
// currently lists get a statement: telling Hyprland about a device it does not
// have is harmless but pointless, and a profile for an absent tablet must not
// hijack a present one with a different identity but the same name.
function applyPlan(document, boxes, presentNames) {
  var doc = normalizeDocument(document)
  var names = presentNames instanceof Array ? presentNames : []
  var statements = []
  var notes = []
  var claimed = {}
  for (var i = 0; i < doc.tablets.length; i++) {
    var profile = doc.tablets[i]
    var hyprlandName = hyprlandDeviceName(profile.kernelName)
    if (hyprlandName === "" || names.indexOf(hyprlandName) === -1 || claimed[hyprlandName]) continue
    var statement = deviceStatement(profile, boxes)
    if (!statement) continue
    claimed[hyprlandName] = true
    statements.push({ lua: statement.lua, id: profile.id, label: profile.label })
    notes = notes.concat(statement.notes)
  }
  statements.push({ lua: stylusStatement(doc.stylus), id: "", label: "Stylus" })
  statements.push({ lua: cursorStatement(doc.stylus), id: "", label: "Cursor" })
  return { statements: statements, notes: notes }
}

// ---------------------------------------------------------------- pen buttons

function buttonActionOptions() {
  return [
    { value: "app", label: "Let the app decide" },
    { value: "left", label: "Left click" },
    { value: "middle", label: "Middle click" },
    { value: "right", label: "Right click" },
    { value: "space", label: "Hold Space (pan in drawing apps)" },
    { value: "scroll", label: "Scroll the page (drag)" }
  ]
}

// What the helper should turn into mouse buttons: only connected tablets,
// only when at least one control is mapped. An empty plan means the helper
// should not run at all.
function penButtonPlan(document, tablets) {
  var doc = normalizeDocument(document)
  var list = tablets instanceof Array ? tablets : []
  var entries = []
  for (var i = 0; i < doc.tablets.length; i++) {
    var profile = doc.tablets[i]
    var buttons = normalizeButtons(profile.buttons)
    if (buttons.button1 === "app" && buttons.button2 === "app" && buttons.eraser === "app") continue
    var live = tabletById(list, profile.id)
    if (!live || !live.present || String(live.node || "") === "") continue
    entries.push({ node: String(live.node), label: String(profile.label || "Tablet"), actions: buttons })
  }
  return { tablets: entries }
}

function penButtonsCommand(pluginDir, plan) {
  return ["python3", String(pluginDir || "").replace(/\/$/, "") + "/tools/pen-buttons.py", JSON.stringify(plan)]
}

function penButtonSummary(profile) {
  var buttons = normalizeButtons((profile || {}).buttons)
  var parts = []
  var labels = { left: "left click", middle: "middle click", right: "right click", space: "hold Space", scroll: "scroll the page" }
  if (buttons.button1 !== "app") parts.push("button 1 → " + labels[buttons.button1])
  if (buttons.button2 !== "app") parts.push("button 2 → " + labels[buttons.button2])
  if (buttons.eraser !== "app") parts.push("eraser → " + labels[buttons.eraser])
  return parts.length ? parts.join(" · ") : "apps decide"
}

// ---------------------------------------------------------------- labels

function monitorLabel(box, compact) {
  var item = box || {}
  var description = String(item.description || "").trim()
  var name = String(item.name || "").trim()
  if (compact === true) return name || description || "Screen"
  if (description === "") return name || "Screen"
  // Drop the trailing serial hex so the label reads like a product name.
  var short = description.replace(/\s+0x[0-9A-Fa-f]+$/, "")
  return short + (name !== "" ? " (" + name + ")" : "")
}

function outputOptions(boxes) {
  var options = [
    { value: "layout", label: "All screens" },
    { value: "current", label: "Follow the focused screen" }
  ]
  var list = boxes || []
  for (var i = 0; i < list.length; i++) {
    options.push({ value: "monitor:" + String((list[i] || {}).name || ""), label: monitorLabel(list[i], false) })
  }
  return options
}

// The dropdown must still show a screen that is remembered but unplugged,
// otherwise its value would silently read as something else.
function outputOptionsFor(profile, boxes) {
  var options = outputOptions(boxes)
  var output = (profile || {}).output || {}
  if (output.mode !== "monitor") return options
  var value = "monitor:" + String(output.name || "")
  for (var i = 0; i < options.length; i++) if (options[i].value === value) return options
  var description = String(output.description || "").replace(/\s+0x[0-9A-Fa-f]+$/, "")
  options.push({ value: value, label: (description || String(output.name || "Screen")) + " · not connected" })
  return options
}

function outputValue(profile) {
  var output = (profile || {}).output || {}
  if (output.mode === "monitor") return "monitor:" + String(output.name || "")
  return output.mode === "current" ? "current" : "layout"
}

function withOutputValue(profile, value, boxes) {
  var next = normalizeProfile(profile, null)
  var text = String(value || "")
  if (text === "current" || text === "layout") {
    next.output = { mode: text, name: "", description: "" }
  } else if (text.indexOf("monitor:") === 0) {
    var name = text.slice("monitor:".length)
    var monitor = findMonitor(boxes, name, "")
    next.output = { mode: "monitor", name: name, description: monitor ? String(monitor.description || "") : "" }
  }
  return next
}

function regionOptions() {
  return [
    { value: "full", label: "Fill the screen" },
    { value: "aspect", label: "Keep tablet proportions" },
    { value: "custom", label: "Custom region" }
  ]
}

function activeAreaOptions() {
  return [
    { value: "full", label: "Whole tablet" },
    { value: "aspect", label: "Match screen proportions" },
    { value: "custom", label: "Custom area" }
  ]
}

function transformOptions() {
  return [
    { value: "0", label: "Normal" },
    { value: "1", label: "Rotate 90°" },
    { value: "2", label: "Rotate 180°" },
    { value: "3", label: "Rotate 270°" },
    { value: "4", label: "Flipped" },
    { value: "5", label: "Flipped, 90°" },
    { value: "6", label: "Flipped, 180°" },
    { value: "7", label: "Flipped, 270°" }
  ]
}

function eraserModeOptions() {
  return [
    { value: "0", label: "Switches to the eraser" },
    { value: "1", label: "Sends a pen button" }
  ]
}

// evdev codes for the stylus buttons libinput reports (BTN_STYLUS family).
function eraserOverrideOptions() {
  return [
    { value: "0", label: "First free pen button" },
    { value: "331", label: "Pen button 1 (BTN_STYLUS)" },
    { value: "332", label: "Pen button 2 (BTN_STYLUS2)" },
    { value: "329", label: "Pen button 3 (BTN_STYLUS3)" }
  ]
}

function optionLabel(options, value) {
  var list = options || []
  for (var i = 0; i < list.length; i++) {
    if (String((list[i] || {}).value) === String(value)) return String(list[i].label || "")
  }
  return String(value || "")
}

function describeOutput(profile, boxes) {
  var output = (profile || {}).output || {}
  if (output.mode === "current") return "focused screen"
  if (output.mode === "monitor") {
    var monitor = findMonitor(boxes, output.name, output.description)
    if (monitor) return monitorLabel(monitor, true)
    var description = String(output.description || "").replace(/\s+0x[0-9A-Fa-f]+$/, "")
    return description || String(output.name || "screen")
  }
  return "all screens"
}

function mappingSummary(profile, boxes) {
  var item = profile || {}
  var parts = [describeOutput(item, boxes)]
  var region = item.region || {}
  if (region.mode === "aspect") parts.push("tablet proportions")
  else if (region.mode === "custom") parts.push("custom region")
  if (item.relativeInput) parts.push("mouse mode")
  if (effectiveTransform(item) !== 0) parts.push(optionLabel(transformOptions(), effectiveTransform(item)).toLowerCase())
  if (item.leftHanded && item.reversible !== false) parts.push("left-handed")
  return parts.join(" · ")
}

// What the Tablet pane says about turning the tablet, in words the person can
// act on.
function rotationSupportLabel(tablet) {
  var item = tablet || {}
  if (item.rotatable !== false) return item.display ? "any angle (display tablet)" : "any angle"
  if (item.reversible !== false) return "180° only, via Left-handed (external tablet)"
  return "none (libinput allows neither rotation nor a left-handed flip)"
}

function padLabel(tablet) {
  var item = tablet || {}
  var parts = []
  if (Number(item.padButtons || 0) > 0) parts.push(item.padButtons + (item.padButtons === 1 ? " button" : " buttons"))
  if (Number(item.rings || 0) > 0) parts.push(item.rings + (item.rings === 1 ? " ring" : " rings"))
  if (Number(item.strips || 0) > 0) parts.push(item.strips + (item.strips === 1 ? " strip" : " strips"))
  if (parts.length === 0) return item.hasPad ? "present (not managed here)" : "none"
  return parts.join(", ") + " (not managed here)"
}

function tabletOptions(profiles, tablets) {
  var options = []
  var connected = {}
  var list = tablets instanceof Array ? tablets : []
  for (var i = 0; i < list.length; i++) connected[String((list[i] || {}).id || "")] = true
  var saved = profiles instanceof Array ? profiles : []
  for (var j = 0; j < saved.length; j++) {
    var profile = saved[j] || {}
    options.push({
      value: String(profile.id || ""),
      label: String(profile.label || "Tablet") + (connected[String(profile.id || "")] ? "" : " · not connected")
    })
  }
  return options
}

function initialTabletId(profiles, tablets, current) {
  var saved = profiles instanceof Array ? profiles : []
  var list = tablets instanceof Array ? tablets : []
  var wanted = String(current || "")
  for (var i = 0; i < saved.length; i++) if (String((saved[i] || {}).id || "") === wanted && wanted !== "") return wanted
  for (var j = 0; j < list.length; j++) {
    var id = String((list[j] || {}).id || "")
    for (var k = 0; k < saved.length; k++) if (String((saved[k] || {}).id || "") === id) return id
  }
  return saved.length ? String((saved[0] || {}).id || "") : ""
}

function tabletById(tablets, id) {
  var list = tablets instanceof Array ? tablets : []
  for (var i = 0; i < list.length; i++) {
    if (String((list[i] || {}).id || "") === String(id || "")) return list[i]
  }
  return null
}

// ---------------------------------------------------------------- canvas

function layoutMetrics(bounds, canvasWidth, canvasHeight, padding) {
  var area = bounds || layoutBounds([])
  var inset = Math.max(0, Number(padding || 0))
  var usableWidth = Math.max(1, Number(canvasWidth || 1) - inset * 2)
  var usableHeight = Math.max(1, Number(canvasHeight || 1) - inset * 2)
  var scale = Math.min(usableWidth / area.width, usableHeight / area.height)
  return {
    scale: scale,
    offsetX: inset + (usableWidth - area.width * scale) / 2,
    offsetY: inset + (usableHeight - area.height * scale) / 2
  }
}

function layoutRect(item, bounds, canvasWidth, canvasHeight, padding) {
  var box = item || {}
  var area = bounds || layoutBounds([])
  var metrics = layoutMetrics(area, canvasWidth, canvasHeight, padding)
  return {
    x: metrics.offsetX + (Number(box.x || 0) - area.x) * metrics.scale,
    y: metrics.offsetY + (Number(box.y || 0) - area.y) * metrics.scale,
    width: Math.max(1, Number(box.width || 1) * metrics.scale),
    height: Math.max(1, Number(box.height || 1) * metrics.scale)
  }
}

// Where the mapped region sits on the screen canvas, in canvas pixels. For a
// "follow the focused screen" mapping there is nothing fixed to draw, so the
// focused monitor stands in for it.
function regionCanvasRect(profile, boxes, canvasWidth, canvasHeight, padding) {
  var list = boxes || []
  if (list.length === 0) return null
  var target = outputTarget(profile, list)
  var box = target.box
  if (!box) {
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].focused) box = list[i]
    if (!box) box = list[0]
  }
  var bounds = layoutBounds(list)
  var rect = layoutRect(box, bounds, canvasWidth, canvasHeight, padding)
  var fractions = target.kind === "current" ? null : regionFractions(profile, box)
  if (!fractions) return { x: rect.x, y: rect.y, width: rect.width, height: rect.height, follows: target.kind === "current" }
  return {
    x: rect.x + rect.width * fractions.x,
    y: rect.y + rect.height * fractions.y,
    width: Math.max(1, rect.width * fractions.w),
    height: Math.max(1, rect.height * fractions.h),
    follows: false
  }
}

// Translates a drag on the canvas back into region fractions of the target.
function regionFromCanvasDrag(profile, boxes, canvasWidth, canvasHeight, padding, deltaX, deltaY) {
  var target = outputTarget(profile, boxes || [])
  if (!target.box) return null
  var rect = layoutRect(target.box, layoutBounds(boxes || []), canvasWidth, canvasHeight, padding)
  var region = clampRegion((profile || {}).region)
  return clampRegion({
    mode: "custom",
    x: region.x + Number(deltaX || 0) / Math.max(1, rect.width),
    y: region.y + Number(deltaY || 0) / Math.max(1, rect.height),
    w: region.w,
    h: region.h
  })
}

function nudgeRegion(profile, dx, dy, dw, dh) {
  var region = clampRegion((profile || {}).region)
  return clampRegion({
    mode: "custom",
    x: region.x + Number(dx || 0),
    y: region.y + Number(dy || 0),
    w: region.w + Number(dw || 0),
    h: region.h + Number(dh || 0)
  })
}

// Area of the tablet drawing that is active, as fractions of the transformed
// tablet, for the canvas.
function activeAreaFractions(profile, boxes) {
  var size = effectiveTabletSize(profile)
  if (size.width <= 0 || size.height <= 0) return null
  var target = outputTarget(profile, boxes || [])
  var area = activeAreaMm(profile, target.box)
  if (!area) return null
  return { x: area.x / size.width, y: area.y / size.height, w: area.w / size.width, h: area.h / size.height }
}

// ---------------------------------------------------------------- updates

// Omarchy clones a plugin once and leaves the checkout alone, so noticing a
// newer version is the plugin's own job. This asks git whether the checkout
// is behind its origin, fetching at most once per `throttleHours` (a stamp
// file in the runtime directory remembers the last fetch), and reports the
// answer through the exit status: 10 when an update is waiting, anything
// else when there is nothing to say (no checkout, no remote, no network).
function pluginUpdateCheckCommand(pluginId, throttleHours) {
  var hours = Number(throttleHours || 6)
  var script = [
    "set -e",
    'checkout="$HOME/.config/omarchy/plugins/$1"',
    '[ -d "$checkout/.git" ] || exit 3',
    'runtime="${XDG_RUNTIME_DIR:-}"',
    '[ -n "$runtime" ] && [ -d "$runtime" ] || exit 6',
    // Only write the stamp into a runtime directory that is really ours.
    '[ "$(stat -c %u:%a -- "$runtime" 2>/dev/null)" = "$(id -u):700" ] || exit 6',
    'stamp="$runtime/$1.update-check"',
    '[ ! -L "$stamp" ] || exit 6',
    'if [ -z "$(find "$stamp" -newermt "-$2 hours" 2>/dev/null)" ]; then',
    '  git -C "$checkout" fetch --quiet origin HEAD 2>/dev/null || exit 4',
    // Truncating creates the stamp when missing and bumps its mtime when
    // not; the symlink check above already refused anything but a plain file.
    '  (umask 077; : > "$stamp") || exit 6',
    "fi",
    'local_head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null) || exit 5',
    'remote_head=$(git -C "$checkout" rev-parse FETCH_HEAD 2>/dev/null) || exit 5',
    '[ "$local_head" = "$remote_head" ] || exit 10'
  ].join("\n")
  return ["sh", "-c", script, "sh", String(pluginId || ""), String(hours)]
}

function pluginUpdateCommand(pluginId) {
  return ["omarchy", "plugin", "update", String(pluginId || ""), "--yes"]
}

// `omarchy plugin update` prints "Updated <id>." when it pulled something and
// "<id> is up to date." otherwise; only the former needs a shell restart.
function pluginUpdated(output) {
  return /^Updated /m.test(String(output || ""))
}

// A shell restart kills the process this panel runs in; setsid detaches the
// command so it survives its parent.
function shellRestartCommand() {
  return ["setsid", "-f", "omarchy-restart-shell"]
}

function wrapIndex(index, length) {
  var count = Math.max(0, Number(length || 0))
  if (count === 0) return 0
  var value = Number(index || 0) % count
  return value < 0 ? value + count : value
}

function cycleOptionValue(options, currentValue, delta) {
  var items = options instanceof Array ? options : []
  if (items.length === 0) return String(currentValue || "")
  var current = 0
  for (var i = 0; i < items.length; i++) {
    var value = items[i] && typeof items[i] === "object" ? items[i].value : items[i]
    if (String(value) === String(currentValue || "")) {
      current = i
      break
    }
  }
  var selected = items[wrapIndex(current + Number(delta || 0), items.length)]
  return String(selected && typeof selected === "object" ? selected.value : selected)
}

if (typeof module !== "undefined") {
  module.exports = {
    hyprlandDeviceName: hyprlandDeviceName,
    safeText: safeText,
    luaString: luaString,
    luaNumber: luaNumber,
    luaVec: luaVec,
    clamp: clamp,
    clone: clone,
    probeScript: probeScript,
    probeCommand: probeCommand,
    hyprctlEvalCommand: hyprctlEvalCommand,
    hyprlandVersionCommand: hyprlandVersionCommand,
    hyprlandSupportsEval: hyprlandSupportsEval,
    splitProbeSections: splitProbeSections,
    parseDeviceBlock: parseDeviceBlock,
    parseLibwacomYaml: parseLibwacomYaml,
    parseLibwacomDb: parseLibwacomDb,
    libwacomEntryFor: libwacomEntryFor,
    busName: busName,
    deviceIds: deviceIds,
    penCapabilities: penCapabilities,
    penLabel: penLabel,
    anyEraserButton: anyEraserButton,
    internalMonitor: internalMonitor,
    cursorStatement: cursorStatement,
    effectiveTransform: effectiveTransform,
    rotationSupportLabel: rotationSupportLabel,
    padLabel: padLabel,
    parseHyprlandTabletNames: parseHyprlandTabletNames,
    parseMonitors: parseMonitors,
    tabletIdentity: tabletIdentity,
    discoverTablets: discoverTablets,
    keyBit: keyBit,
    kernelPenCapabilities: kernelPenCapabilities,
    parseProbe: parseProbe,
    stylusSummary: stylusSummary,
    tabletSizeLabel: tabletSizeLabel,
    defaultStylus: defaultStylus,
    defaultProfile: defaultProfile,
    normalizeProfile: normalizeProfile,
    clampRegion: clampRegion,
    normalizeStylus: normalizeStylus,
    normalizeDocument: normalizeDocument,
    parseDocument: parseDocument,
    serializeDocument: serializeDocument,
    documentPath: documentPath,
    saveCommand: saveCommand,
    profileById: profileById,
    upsertProfile: upsertProfile,
    removeProfile: removeProfile,
    mergeDiscovered: mergeDiscovered,
    layoutBounds: layoutBounds,
    transformSwapsAxes: transformSwapsAxes,
    effectiveTabletSize: effectiveTabletSize,
    findMonitor: findMonitor,
    outputTarget: outputTarget,
    fitAspect: fitAspect,
    regionFractions: regionFractions,
    regionPixels: regionPixels,
    activeAreaMm: activeAreaMm,
    deviceStatement: deviceStatement,
    stylusStatement: stylusStatement,
    applyPlan: applyPlan,
    monitorLabel: monitorLabel,
    outputOptions: outputOptions,
    outputOptionsFor: outputOptionsFor,
    normalizeButtons: normalizeButtons,
    buttonActionOptions: buttonActionOptions,
    penButtonPlan: penButtonPlan,
    penButtonsCommand: penButtonsCommand,
    penButtonSummary: penButtonSummary,
    outputValue: outputValue,
    withOutputValue: withOutputValue,
    regionOptions: regionOptions,
    activeAreaOptions: activeAreaOptions,
    transformOptions: transformOptions,
    eraserModeOptions: eraserModeOptions,
    eraserOverrideOptions: eraserOverrideOptions,
    optionLabel: optionLabel,
    describeOutput: describeOutput,
    mappingSummary: mappingSummary,
    tabletOptions: tabletOptions,
    initialTabletId: initialTabletId,
    tabletById: tabletById,
    layoutMetrics: layoutMetrics,
    layoutRect: layoutRect,
    regionCanvasRect: regionCanvasRect,
    regionFromCanvasDrag: regionFromCanvasDrag,
    nudgeRegion: nudgeRegion,
    activeAreaFractions: activeAreaFractions,
    pluginUpdateCheckCommand: pluginUpdateCheckCommand,
    shellRestartCommand: shellRestartCommand,
    pluginUpdated: pluginUpdated,
    pluginUpdateCommand: pluginUpdateCommand,
    wrapIndex: wrapIndex,
    cycleOptionValue: cycleOptionValue
  }
}
