#!/usr/bin/env python3
"""Turn pen buttons into real mouse buttons or a held key, system wide.

Hyprland hands pen buttons only to apps that speak the Wayland tablet
protocol; everything else sees the pointer move and nothing more. This helper
reads the tablet's evdev node (read-only, never grabbed, so libinput keeps
it) and, when a pen button or the eraser end is used, presses the configured
mouse button on a virtual pointer or holds a key on a virtual keyboard. Both
are Wayland objects offered by Hyprland itself (zwlr_virtual_pointer_v1 and
zwp_virtual_keyboard_v1), so no device node, udev rule or privilege is
needed. The click lands where the pen already put the cursor.

    tools/pen-buttons.py '<json>'      run with a plan (see penButtonPlan in Model.js)
    tools/pen-buttons.py --check       report whether the compositor offers virtual input
    tools/pen-buttons.py --self-test   press a fake pen's buttons and check what would be sent

Plan: {"tablets": [{"node": "/dev/input/by-id/...", "label": "...",
        "actions": {"button1": "right", "button2": "middle", "eraser": "left"}}]}
Actions: "app" (leave to the app), "left", "middle", "right", "space"
(hold the Space key while the pen button is held: the pan gesture of
Excalidraw, Krita, GIMP, Inkscape and most other drawing apps, without the
primary-selection paste a middle click causes in browsers), or "scroll"
(hold the button and move the pen to scroll the page, in any app).
Only standard library; nothing to install.
"""
import array, ctypes, json, os, select, socket, struct, subprocess, sys, time

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2, BTN_STYLUS3 = 0x140, 0x141, 0x14a, 0x14b, 0x14c, 0x149
KEY_SPACE = 0x39
ABS_X, ABS_Y = 0x00, 0x01
# How much page scroll one unit of pen travel is worth. The pen reports
# ~100 units per millimetre, so ~0.55 px per unit turns a couple of
# centimetres of drag into most of a screen.
SCROLL_GAIN = 0.55
AXIS_VERTICAL = 0

# action name -> (device, evdev code)
ACTIONS = {"left": ("pointer", BTN_LEFT), "right": ("pointer", BTN_RIGHT), "middle": ("pointer", BTN_MIDDLE), "space": ("keyboard", KEY_SPACE), "scroll": ("scroll", 0)}
EVENT = struct.Struct("llHHi")
NAMES = {BTN_LEFT: "left", BTN_RIGHT: "right", BTN_MIDDLE: "middle", KEY_SPACE: "space"}


# --- Wayland: just enough of the wire protocol for two virtual devices ------

# A keymap with the one key the keyboard sends. The compositor compiles it
# with xkbcommon and hands it to the focused app while this keyboard is in
# use; the app sees evdev code 57 as XKB keycode 65, "space".
KEYMAP = """xkb_keymap {
xkb_keycodes { minimum = 8; maximum = 255; <K57> = 65; };
xkb_types { type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; }; };
xkb_compatibility { };
xkb_symbols { key <K57> { [ space ] }; };
};
"""

WL_DISPLAY, WL_REGISTRY, SYNC_CALLBACK, WL_SEAT, POINTER_MANAGER, KEYBOARD_MANAGER, POINTER, KEYBOARD = 1, 2, 3, 4, 5, 6, 7, 8


def wl_string(text):
    data = text.encode() + b"\0"
    return struct.pack("<I", len(data)) + data + b"\0" * (-len(data) % 4)


class Wayland:
    """The compositor connection, a virtual pointer and, on request, a
    virtual keyboard. Only registry events are ever read."""

    def __init__(self):
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        if not runtime:
            raise OSError("XDG_RUNTIME_DIR is not set; is this a Wayland session?")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(display if display.startswith("/") else os.path.join(runtime, display))
        self.globals = {}
        self.buffer = b""
        self.keyboard_ready = False
        self.send(WL_DISPLAY, 1, struct.pack("<I", WL_REGISTRY))  # get_registry
        self.roundtrip()
        for interface in ("wl_seat", "zwlr_virtual_pointer_manager_v1", "zwp_virtual_keyboard_manager_v1"):
            if interface not in self.globals:
                raise OSError(f"the compositor does not offer {interface}")
        self.bind("wl_seat", WL_SEAT, 1)
        self.bind("zwlr_virtual_pointer_manager_v1", POINTER_MANAGER, 1)
        self.bind("zwp_virtual_keyboard_manager_v1", KEYBOARD_MANAGER, 1)
        # zwlr_virtual_pointer_manager_v1.create_virtual_pointer(seat, id)
        self.send(POINTER_MANAGER, 0, struct.pack("<II", WL_SEAT, POINTER))
        self.roundtrip()

    def send(self, obj, opcode, payload=b"", fds=()):
        data = struct.pack("<II", obj, ((8 + len(payload)) << 16) | opcode) + payload
        if fds:
            self.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            self.sock.sendall(data)

    def bind(self, interface, new_id, version):
        name, offered = self.globals[interface]
        self.send(WL_REGISTRY, 0, struct.pack("<I", name) + wl_string(interface) + struct.pack("<II", min(version, offered), new_id))

    def roundtrip(self):
        self.send(WL_DISPLAY, 0, struct.pack("<I", SYNC_CALLBACK))  # sync
        while True:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OSError("the compositor closed the connection")
            self.buffer += chunk
            if self.drain():
                return

    def drain(self):
        """Handle buffered events; True once the sync callback fired."""
        done = False
        while len(self.buffer) >= 8:
            obj, sizeop = struct.unpack_from("<II", self.buffer)
            size, opcode = sizeop >> 16, sizeop & 0xffff
            if len(self.buffer) < size:
                break
            body = self.buffer[8:size]
            self.buffer = self.buffer[size:]
            if obj == WL_REGISTRY and opcode == 0:  # global(name, interface, version)
                name, length = struct.unpack_from("<II", body)
                interface = body[8:8 + length - 1].decode()
                version = struct.unpack_from("<I", body, 8 + ((length + 3) & ~3))[0]
                self.globals[interface] = (name, version)
            elif obj == SYNC_CALLBACK and opcode == 0:
                done = True
            elif obj == WL_DISPLAY and opcode == 0:  # error(object, code, message)
                _, _, length = struct.unpack_from("<III", body)
                raise OSError("compositor error: " + body[12:12 + length - 1].decode(errors="replace"))
        return done

    def poll(self):
        """Read whatever the compositor sent; raises when it goes away."""
        try:
            chunk = self.sock.recv(65536, socket.MSG_DONTWAIT)
        except BlockingIOError:
            return
        if not chunk:
            raise OSError("the compositor closed the connection")
        self.buffer += chunk
        self.drain()

    def ensure_keyboard(self):
        if self.keyboard_ready:
            return
        # zwp_virtual_keyboard_manager_v1.create_virtual_keyboard(seat, id)
        self.send(KEYBOARD_MANAGER, 0, struct.pack("<II", WL_SEAT, KEYBOARD))
        data = KEYMAP.encode() + b"\0"
        fd = os.memfd_create("omarchy-drawing-tablet-keymap")
        os.write(fd, data)
        # zwp_virtual_keyboard_v1.keymap(format = XKB_V1, fd, size)
        self.send(KEYBOARD, 0, struct.pack("<II", 1, len(data)), fds=(fd,))
        os.close(fd)
        self.roundtrip()
        self.keyboard_ready = True

    @staticmethod
    def now():
        return int(time.monotonic() * 1000) & 0xffffffff

    def press(self, action, down):
        device, code = action
        state = 1 if down else 0
        if device == "pointer":
            if code == BTN_RIGHT and down and not cursor_over_a_window():
                # Qt 6.11 crashes the Omarchy shell when a right click reaches
                # one of its surfaces (wallpaper, bar, panels); see README.
                print("right click skipped: the pen is not over an application window", file=sys.stderr)
                return
            # zwlr_virtual_pointer_v1.button(time, button, state) then frame()
            self.send(POINTER, 2, struct.pack("<III", self.now(), code, state))
            self.send(POINTER, 4)  # frame
        elif device == "scroll":
            return  # scrolling is driven by pen motion, not button state
        else:
            self.ensure_keyboard()
            # zwp_virtual_keyboard_v1.key(time, key, state)
            self.send(KEYBOARD, 1, struct.pack("<III", self.now(), code, state))

    def scroll(self, value_fixed):
        # zwlr_virtual_pointer_v1: axis_source(finger), axis(vertical, value), frame
        self.send(POINTER, 5, struct.pack("<I", 1))  # axis_source = finger
        self.send(POINTER, 3, struct.pack("<IIi", self.now(), AXIS_VERTICAL, value_fixed))
        self.send(POINTER, 4)  # frame

    def scroll_stop(self):
        # axis_stop(time, axis), frame — ends the kinetic gesture cleanly.
        self.send(POINTER, 6, struct.pack("<II", self.now(), AXIS_VERTICAL))
        self.send(POINTER, 4)

    def close(self):
        self.sock.close()


class Recorder:
    """Stands in for the compositor in the self-test."""

    def __init__(self):
        self.sent = []

    def press(self, action, down):
        self.sent.append((action[1], 1 if down else 0))

    def scroll(self, value_fixed):
        self.sent.append(("scroll", value_fixed))

    def scroll_stop(self):
        self.sent.append(("scroll_stop", 0))

    def poll(self):
        pass

    def close(self):
        pass


# --- The tablet side ---------------------------------------------------------

def hyprctl(*args):
    try:
        out = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True, timeout=1)
        return json.loads(out.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def inside(point, window):
    x, y = point
    (wx, wy), (ww, wh) = window.get("at", (0, 0)), window.get("size", (0, 0))
    return wx <= x < wx + ww and wy <= y < wy + wh


def cursor_over_a_window():
    """Whether the pointer is over an application window rather than a shell
    surface. Only mapped windows on the workspace shown on their monitor
    count; anything else under the pointer is a layer (wallpaper, bar, a
    panel) or nothing."""
    cursor = hyprctl("cursorpos")
    clients = hyprctl("clients")
    monitors = hyprctl("monitors")
    if not isinstance(cursor, dict) or not isinstance(clients, list) or not isinstance(monitors, list):
        return True  # cannot tell: do not swallow the click
    point = (cursor.get("x", 0), cursor.get("y", 0))
    shown = {m.get("id"): (m.get("activeWorkspace") or {}).get("id") for m in monitors}
    for window in clients:
        if not window.get("mapped") or window.get("hidden"):
            continue
        if shown.get(window.get("monitor")) != (window.get("workspace") or {}).get("id"):
            continue
        if inside(point, window):
            return True
    return False


def check():
    try:
        wayland = Wayland()
    except OSError as error:
        print(f"virtual input unavailable: {error}", file=sys.stderr)
        return 2
    wayland.close()
    print("virtual input ok")
    return 0


class Tablet:
    def __init__(self, spec):
        self.node = str(spec.get("node", ""))
        self.label = str(spec.get("label", self.node))
        actions = spec.get("actions") or {}
        self.button1 = ACTIONS.get(str(actions.get("button1", "app")))
        self.button2 = ACTIONS.get(str(actions.get("button2", "app")))
        self.eraser = ACTIONS.get(str(actions.get("eraser", "app")))
        self.fd = None
        self.eraser_near = False
        self.pressed = {}
        self.cur_y = None
        self.last_y = None

    def wanted(self):
        return any((self.button1, self.button2, self.eraser))

    def open(self):
        if self.fd is None:
            self.fd = open_readable(self.node)
        return self.fd

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    @property
    def scrolling(self):
        return any(a[0] == "scroll" for a in self.pressed.values())

    def feed(self, out, typ, code, value):
        if typ == EV_KEY:
            self.handle_key(out, code, value)
        elif typ == EV_ABS:
            if code == ABS_Y:
                self.cur_y = value
        elif typ == EV_SYN and code == SYN_REPORT and self.scrolling and self.cur_y is not None:
            # Content follows the pen: dragging up reveals what is below, the
            # touchscreen-style pan. One axis event per report frame.
            if self.last_y is not None and self.cur_y != self.last_y:
                out.scroll(int(-(self.cur_y - self.last_y) * SCROLL_GAIN * 256))
            self.last_y = self.cur_y

    def handle_key(self, out, code, value):
        # A press maps to an action; the release always goes to whatever
        # was pressed, so a plan change mid-press cannot leave a button stuck.
        if code == BTN_TOOL_RUBBER:
            self.eraser_near = value == 1
            if not self.eraser_near:
                self.release(out, "eraser")
            return
        if code == BTN_STYLUS:
            self.press_or_release(out, "button1", self.button1, value)
        elif code == BTN_STYLUS2:
            self.press_or_release(out, "button2", self.button2, value)
        elif code == BTN_TOUCH and self.eraser_near:
            self.press_or_release(out, "eraser", self.eraser, value)

    def press_or_release(self, out, key, action, value):
        if value == 1:
            if action is None or key in self.pressed:
                return
            self.pressed[key] = action
            if action[0] == "scroll":
                self.last_y = self.cur_y  # anchor here; the next frame is the delta
            else:
                out.press(action, True)
        else:
            self.release(out, key)

    def release(self, out, key):
        action = self.pressed.pop(key, None)
        if action is None:
            return
        if action[0] == "scroll":
            if not self.scrolling:
                out.scroll_stop()
        else:
            out.press(action, False)

    def release_all(self, out):
        for key in list(self.pressed):
            self.release(out, key)


def open_readable(node, tries=30):
    """Open a node that udev may not have handed to the user yet: a node that
    has just appeared belongs to root until udev has run its rules."""
    for attempt in range(tries):
        try:
            return os.open(node, os.O_RDONLY | os.O_NONBLOCK)
        except PermissionError:
            if attempt == tries - 1:
                raise
            time.sleep(0.1)


def die_with_parent():
    """Exit when the shell that started us goes away, so a restart never
    leaves a second helper behind."""
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, 15)  # PR_SET_PDEATHSIG, SIGTERM
    except OSError:
        pass


def pump(tablets, out, stop=None):
    """Read the tablets and drive `out` until they are all gone, `stop()`
    says so, or the compositor disappears."""
    by_fd = {}
    for tablet in tablets:
        try:
            by_fd[tablet.open()] = tablet
            print(f"watching {tablet.label} ({tablet.node})", file=sys.stderr)
        except OSError as error:
            print(f"cannot read {tablet.node}: {error}", file=sys.stderr)
    if not by_fd:
        return 1
    try:
        while by_fd and not (stop and stop()):
            ready, _, _ = select.select(list(by_fd), [], [], 0.5)
            out.poll()
            for fd in ready:
                tablet = by_fd[fd]
                try:
                    data = os.read(fd, EVENT.size * 64)
                except OSError:
                    # Unplugged: the service restarts us when the tablet is back.
                    tablet.release_all(out)
                    tablet.close()
                    del by_fd[fd]
                    continue
                for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                    _, _, typ, code, value = EVENT.unpack_from(data, offset)
                    tablet.feed(out, typ, code, value)
    finally:
        for tablet in by_fd.values():
            tablet.release_all(out)
            tablet.close()
    return 0


def run(plan):
    die_with_parent()
    tablets = [Tablet(spec) for spec in plan.get("tablets", [])]
    tablets = [t for t in tablets if t.wanted() and t.node]
    if not tablets:
        print("nothing to do: no pen button actions configured", file=sys.stderr)
        return 0
    try:
        out = Wayland()
    except OSError as error:
        print(f"virtual input unavailable: {error}", file=sys.stderr)
        return 2
    try:
        return pump(tablets, out)
    except OSError as error:
        print(f"stopping: {error}", file=sys.stderr)
        return 2
    finally:
        out.close()


# --- Self-test: a fake pen made with uinput, outputs recorded ---------------

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_ABS_SETUP = 0x401c5504  # _IOW(UINPUT_IOCTL_BASE, 4, struct uinput_abs_setup)
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_DEV_SETUP = 0x405c5503  # _IOW(UINPUT_IOCTL_BASE, 3, struct uinput_setup)


def emit(fd, typ, code, value):
    now = time.time()
    os.write(fd, EVENT.pack(int(now), int((now - int(now)) * 1_000_000), typ, code, value))


def node_named(name, tries=50):
    """Find /dev/input/eventN for a device by its kernel name, waiting for udev."""
    import glob
    for _ in range(tries):
        for sysfs in glob.glob("/sys/class/input/event*"):
            try:
                with open(sysfs + "/device/name") as handle:
                    if handle.read().strip() == name:
                        return "/dev/input/" + os.path.basename(sysfs)
            except OSError:
                pass
        time.sleep(0.1)
    return None


def fake_tablet():
    """A uinput pen tablet with the same buttons a real one reports. Only the
    self-test needs uinput; the helper itself never touches it."""
    import fcntl
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in (EV_KEY, EV_ABS, EV_SYN):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for code in (BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    for axis, maximum, resolution in ((0, 21600, 100), (1, 13500, 100), (24, 2047, 0)):
        fcntl.ioctl(fd, UI_SET_ABSBIT, axis)
        # struct uinput_abs_setup { __u16 code; struct input_absinfo { __s32 value, minimum, maximum, fuzz, flat, resolution; } }
        fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("Hxxiiiiii", axis, 0, 0, maximum, 0, 0, resolution))
    name = b"Drawing Tablet for Omarchy self-test pen"
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x06, 0x0a11, 0x0dd2, 1, name.ljust(80, b"\0"), 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd, name.decode()


def self_test():
    import fcntl, threading
    try:
        tablet_fd, tablet_name = fake_tablet()
    except OSError as error:
        print(f"self-test: uinput unavailable for the fake pen: {error}", file=sys.stderr)
        return 2
    try:
        node = node_named(tablet_name)
        if not node:
            print("self-test: fake tablet never appeared", file=sys.stderr)
            return 1
        tablet = Tablet({"node": node, "label": "self-test", "actions": {"button1": "right", "button2": "space", "eraser": "left"}})
        out = Recorder()
        finished = threading.Event()
        worker = threading.Thread(target=pump, args=([tablet], out, finished.is_set), daemon=True)
        worker.start()
        time.sleep(0.5)

        def key(code, value):
            emit(tablet_fd, EV_KEY, code, value)
            emit(tablet_fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(0.05)

        def move(y):
            emit(tablet_fd, EV_ABS, ABS_Y, y)
            emit(tablet_fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(0.05)

        # Pen comes near, button 1 press/release, button 2 press/release,
        # then the eraser end touches and lifts.
        for code, value in [(BTN_TOOL_PEN, 1), (BTN_STYLUS, 1), (BTN_STYLUS, 0), (BTN_STYLUS2, 1), (BTN_STYLUS2, 0),
                            (BTN_TOOL_PEN, 0), (BTN_TOOL_RUBBER, 1), (BTN_TOUCH, 1), (BTN_TOUCH, 0), (BTN_TOOL_RUBBER, 0)]:
            key(code, value)
        expected = [(BTN_RIGHT, 1), (BTN_RIGHT, 0), (KEY_SPACE, 1), (KEY_SPACE, 0), (BTN_LEFT, 1), (BTN_LEFT, 0)]
        deadline = time.time() + 3
        while time.time() < deadline and len(out.sent) < len(expected):
            time.sleep(0.05)
        if out.sent != expected:
            finished.set(); worker.join(1)
            print(f"self-test FAILED: buttons: expected {[(NAMES[c], v) for c, v in expected]}, got {[(NAMES.get(c, hex(c)), v) for c, v in out.sent]}", file=sys.stderr)
            return 1

        # Scroll: hold a scroll-mapped button and drag the pen up, then down.
        tablet.button2 = ACTIONS["scroll"]
        out.sent.clear()
        move(8000)                 # anchor
        key(BTN_STYLUS2, 1)        # start scrolling
        move(7000); move(6000)     # pen up -> scroll down (positive)
        move(7000)                 # pen down -> scroll up (negative)
        key(BTN_STYLUS2, 0)        # stop
        deadline = time.time() + 2
        while time.time() < deadline and not any(e[0] == "scroll_stop" for e in out.sent):
            time.sleep(0.05)
        finished.set()
        worker.join(2)
        scrolls = [v for kind, v in out.sent if kind == "scroll"]
        if not (len(scrolls) >= 3 and scrolls[0] > 0 and scrolls[1] > 0 and scrolls[-1] < 0 and out.sent[-1][0] == "scroll_stop"):
            print(f"self-test FAILED: scroll: got {out.sent}", file=sys.stderr)
            return 1
        print("self-test ok: button 1 -> right click, button 2 -> hold Space, eraser -> left click, scroll drag -> axis events")
        return 0
    finally:
        fcntl.ioctl(tablet_fd, UI_DEV_DESTROY)
        os.close(tablet_fd)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 64
    if argv[1] == "--check":
        return check()
    if argv[1] == "--self-test":
        return self_test()
    try:
        plan = json.loads(argv[1])
    except ValueError as error:
        print(f"bad plan: {error}", file=sys.stderr)
        return 64
    return run(plan)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
