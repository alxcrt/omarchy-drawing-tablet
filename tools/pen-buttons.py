#!/usr/bin/env python3
"""Turn pen buttons into real mouse buttons, system wide.

Hyprland hands pen buttons only to apps that speak the Wayland tablet
protocol; everything else sees the pointer move and nothing more. This helper
reads the tablet's evdev node (read-only, never grabbed, so libinput keeps
it) and presses the configured mouse button on a virtual mouse when a pen
button or the eraser end is used. The click lands where the pen already put
the cursor.

    tools/pen-buttons.py '<json>'      run with a plan (see penButtonPlan in Model.js)
    tools/pen-buttons.py --check       report whether /dev/uinput can be opened
    tools/pen-buttons.py --self-test   press a fake pen's buttons and check the clicks come out

Plan: {"tablets": [{"node": "/dev/input/by-id/...", "label": "...",
        "actions": {"button1": "right", "button2": "middle", "eraser": "left"}}]}
Actions: "app" (leave to the app), "left", "middle", "right", or "space"
(hold the Space key while the pen button is held: the pan gesture of
Excalidraw, Krita, GIMP, Inkscape and most other drawing apps, without the
primary-selection paste a middle click causes in browsers).
Only standard library; nothing to install.
"""
import fcntl, json, os, select, struct, sys, time, ctypes

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0x00, 0x01, 0x02, 0x03
SYN_REPORT = 0
REL_X, REL_Y = 0x00, 0x01
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
KEY_ESC, KEY_D, KEY_SPACE = 0x01, 0x20, 0x39
BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2, BTN_STYLUS3 = 0x140, 0x141, 0x14a, 0x14b, 0x14c, 0x149
INPUT_PROP_POINTER = 0x00

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_SET_ABSBIT, UI_SET_PROPBIT = 0x40045564, 0x40045565, 0x40045566, 0x40045567, 0x4004556e
UI_ABS_SETUP = 0x401c5504  # _IOW(UINPUT_IOCTL_BASE, 4, struct uinput_abs_setup)
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_DEV_SETUP = 0x405c5503  # _IOW(UINPUT_IOCTL_BASE, 3, struct uinput_setup)

# action name -> (device, evdev code)
ACTIONS = {"left": ("mouse", BTN_LEFT), "right": ("mouse", BTN_RIGHT), "middle": ("mouse", BTN_MIDDLE), "space": ("keys", KEY_SPACE)}
EVENT = struct.Struct("llHHi")


MOUSE_NAME = "Drawing Tablet for Omarchy pen buttons"


def open_uinput(name=MOUSE_NAME):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # A pointer needs relative axes to be classified as a mouse by udev and
    # libinput, even though this device never moves.
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    fcntl.ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER)
    # struct uinput_setup { struct input_id id; char name[80]; __u32 ff_effects_max; }
    # struct input_id { __u16 bustype, vendor, product, version; }
    setup = struct.pack("HHHH80sI", 0x06, 0x0a11, 0x0dd1, 1, name.encode()[:79].ljust(80, b"\0"), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def open_keyboard(name):
    """A virtual keyboard for key actions, separate from the mouse so libinput
    keeps seeing a plain mouse. It advertises the ESC..D block as well so
    udev tags it a keyboard rather than a bare key device."""
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in range(KEY_ESC, KEY_D + 1):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_SPACE)
    setup = struct.pack("HHHH80sI", 0x06, 0x0a11, 0x0dd3, 1, name.encode()[:79].ljust(80, b"\0"), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


class Outputs:
    """The virtual devices the actions land on; the keyboard exists only when
    a key action is configured."""

    def __init__(self, mouse_name, keys_name, want_keys):
        self.mouse = open_uinput(mouse_name)
        self.keys = open_keyboard(keys_name) if want_keys else None

    def fd_for(self, device):
        return self.keys if device == "keys" else self.mouse

    def close(self):
        for fd in (self.mouse, self.keys):
            if fd is not None:
                fcntl.ioctl(fd, UI_DEV_DESTROY)
                os.close(fd)


def emit(fd, typ, code, value):
    now = time.time()
    sec, usec = int(now), int((now - int(now)) * 1_000_000)
    os.write(fd, EVENT.pack(sec, usec, typ, code, value))


def click(outputs, action, down):
    device, code = action
    fd = outputs.fd_for(device)
    emit(fd, EV_KEY, code, 1 if down else 0)
    emit(fd, EV_SYN, SYN_REPORT, 0)


def check():
    try:
        fd = open_uinput()
    except OSError as error:
        print(f"uinput unavailable: {error}", file=sys.stderr)
        return 2
    time.sleep(0.2)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
    print("uinput ok")
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

    def wanted(self):
        return any((self.button1, self.button2, self.eraser))

    def wants_keys(self):
        return any(action and action[0] == "keys" for action in (self.button1, self.button2, self.eraser))

    def open(self):
        # A node that has just appeared belongs to root until udev has run
        # its rules; give it a moment rather than failing on the first try.
        if self.fd is None:
            for attempt in range(30):
                try:
                    self.fd = os.open(self.node, os.O_RDONLY | os.O_NONBLOCK)
                    break
                except PermissionError:
                    if attempt == 29:
                        raise
                    time.sleep(0.1)
        return self.fd

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def handle(self, ui, code, value):
        # A press maps to a mouse button; the release always goes to whatever
        # was pressed, so a plan change mid-press cannot leave a button stuck.
        if code == BTN_TOOL_RUBBER:
            self.eraser_near = value == 1
            if not self.eraser_near:
                self.release(ui, "eraser")
            return
        if code == BTN_STYLUS:
            self.press_or_release(ui, "button1", self.button1, value)
        elif code == BTN_STYLUS2:
            self.press_or_release(ui, "button2", self.button2, value)
        elif code == BTN_TOUCH and self.eraser_near:
            self.press_or_release(ui, "eraser", self.eraser, value)

    def press_or_release(self, ui, key, button, value):
        if value == 1:
            if button is None or key in self.pressed:
                return
            self.pressed[key] = button
            click(ui, button, True)
        else:
            self.release(ui, key)

    def release(self, ui, key):
        button = self.pressed.pop(key, None)
        if button is not None:
            click(ui, button, False)

    def release_all(self, ui):
        for key in list(self.pressed):
            self.release(ui, key)


def die_with_parent():
    """Exit when the shell that started us goes away, so a restart never
    leaves a second virtual mouse behind."""
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, 15)  # PR_SET_PDEATHSIG, SIGTERM
    except OSError:
        pass


def run(plan):
    die_with_parent()
    tablets = [Tablet(spec) for spec in plan.get("tablets", [])]
    tablets = [t for t in tablets if t.wanted() and t.node]
    if not tablets:
        print("nothing to do: no pen button actions configured", file=sys.stderr)
        return 0
    # The self-test names its devices differently so it never finds the copies
    # the background service is already running.
    mouse_name = str(plan.get("mouseName") or MOUSE_NAME)
    ui = Outputs(mouse_name, mouse_name + " keys", any(t.wants_keys() for t in tablets))
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
        while by_fd:
            ready, _, _ = select.select(list(by_fd), [], [], 1.0)
            for fd in ready:
                tablet = by_fd[fd]
                try:
                    data = os.read(fd, EVENT.size * 64)
                except OSError:
                    # Unplugged: the service restarts us when the tablet is back.
                    tablet.release_all(ui)
                    tablet.close()
                    del by_fd[fd]
                    continue
                for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                    _, _, typ, code, value = EVENT.unpack_from(data, offset)
                    if typ == EV_KEY:
                        tablet.handle(ui, code, value)
    finally:
        for tablet in by_fd.values():
            tablet.release_all(ui)
        ui.close()
    return 0


def open_readable(node, tries=30):
    """Open a node that udev may not have handed to the user yet."""
    for attempt in range(tries):
        try:
            return os.open(node, os.O_RDONLY | os.O_NONBLOCK)
        except PermissionError:
            if attempt == tries - 1:
                raise
            time.sleep(0.1)


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
    """A uinput pen tablet with the same buttons a real one reports."""
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
    import subprocess
    try:
        tablet_fd, tablet_name = fake_tablet()
    except OSError as error:
        print(f"self-test: uinput unavailable: {error}", file=sys.stderr)
        return 2
    try:
        tablet_node = node_named(tablet_name)
        if not tablet_node:
            print("self-test: fake tablet never appeared", file=sys.stderr)
            return 1
        mouse_name = "Drawing Tablet for Omarchy self-test mouse"
        plan = {"mouseName": mouse_name, "tablets": [{"node": tablet_node, "label": "self-test", "actions": {"button1": "right", "button2": "space", "eraser": "left"}}]}
        helper = subprocess.Popen([sys.executable, os.path.abspath(__file__), json.dumps(plan)], stderr=subprocess.PIPE, text=True)
        try:
            mouse_node = node_named(mouse_name)
            keys_node = node_named(mouse_name + " keys")
            if not mouse_node or not keys_node:
                print("self-test: virtual mouse or keyboard never appeared", file=sys.stderr)
                return 1
            mouse = open_readable(mouse_node)
            keys = open_readable(keys_node)
            time.sleep(0.3)

            def press(code, value):
                emit(tablet_fd, EV_KEY, code, value)
                emit(tablet_fd, EV_SYN, SYN_REPORT, 0)

            # Pen comes near, button 1 press/release, button 2 press/release,
            # then the eraser end touches and lifts.
            script = [(BTN_TOOL_PEN, 1), (BTN_STYLUS, 1), (BTN_STYLUS, 0), (BTN_STYLUS2, 1), (BTN_STYLUS2, 0),
                      (BTN_TOOL_PEN, 0), (BTN_TOOL_RUBBER, 1), (BTN_TOUCH, 1), (BTN_TOUCH, 0), (BTN_TOOL_RUBBER, 0)]
            for code, value in script:
                press(code, value)
                time.sleep(0.05)
            expected = [(BTN_RIGHT, 1), (BTN_RIGHT, 0), (KEY_SPACE, 1), (KEY_SPACE, 0), (BTN_LEFT, 1), (BTN_LEFT, 0)]
            got = []
            deadline = time.time() + 3
            while time.time() < deadline and len(got) < len(expected):
                ready, _, _ = select.select([mouse, keys], [], [], 0.2)
                for fd in ready:
                    data = os.read(fd, EVENT.size * 64)
                    for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                        sec, usec, typ, code, value = EVENT.unpack_from(data, offset)
                        if typ == EV_KEY:
                            got.append((sec, usec, code, value))
            os.close(mouse)
            os.close(keys)
            # Two devices, one timeline: order by the event clock.
            got = [(code, value) for _, _, code, value in sorted(got)]
            if got != expected:
                names = {BTN_LEFT: "left", BTN_RIGHT: "right", BTN_MIDDLE: "middle", KEY_SPACE: "space"}
                print(f"self-test FAILED: expected {[(names[c], v) for c, v in expected]}, got {[(names.get(c, hex(c)), v) for c, v in got]}", file=sys.stderr)
                return 1
            print("self-test ok: button 1 -> right click, button 2 -> hold Space, eraser -> left click")
            return 0
        finally:
            helper.terminate()
            try:
                helper.wait(timeout=3)
            except subprocess.TimeoutExpired:
                helper.kill()
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
