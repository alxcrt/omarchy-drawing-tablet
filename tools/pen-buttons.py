#!/usr/bin/env python3
"""Turn pen buttons into real mouse buttons, system wide.

Hyprland hands pen buttons only to apps that speak the Wayland tablet
protocol; everything else sees the pointer move and nothing more. This helper
reads the tablet's evdev node (read-only, never grabbed, so libinput keeps
it) and presses the configured mouse button on a virtual mouse when a pen
button or the eraser end is used. The click lands where the pen already put
the cursor.

    tools/pen-buttons.py '<json>'      run with a plan (see planForHelper in Model.js)
    tools/pen-buttons.py --check       report whether /dev/uinput can be opened

Plan: {"tablets": [{"node": "/dev/input/by-id/...", "label": "...",
        "actions": {"button1": "right", "button2": "middle", "eraser": "left"}}]}
Actions: "app" (leave to the app), "left", "middle", "right".
Only standard library; nothing to install.
"""
import fcntl, json, os, select, struct, sys, time, ctypes

EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
REL_X, REL_Y = 0x00, 0x01
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS, BTN_STYLUS2, BTN_STYLUS3 = 0x140, 0x141, 0x14a, 0x14b, 0x14c, 0x149
INPUT_PROP_POINTER = 0x00

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_SET_PROPBIT = 0x40045564, 0x40045565, 0x40045566, 0x4004556e
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_DEV_SETUP = 0x405c5503  # _IOW(UINPUT_IOCTL_BASE, 3, struct uinput_setup)

MOUSE = {"left": BTN_LEFT, "right": BTN_RIGHT, "middle": BTN_MIDDLE}
EVENT = struct.Struct("llHHi")


def open_uinput():
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
    name = b"Drawing Tablet for Omarchy pen buttons"
    setup = struct.pack("HHHH80sI", 0x06, 0x0a11, 0x0dd1, 1, name.ljust(80, b"\0"), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, typ, code, value):
    now = time.time()
    sec, usec = int(now), int((now - int(now)) * 1_000_000)
    os.write(fd, EVENT.pack(sec, usec, typ, code, value))


def click(fd, button, down):
    emit(fd, EV_KEY, button, 1 if down else 0)
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
        self.button1 = MOUSE.get(str(actions.get("button1", "app")))
        self.button2 = MOUSE.get(str(actions.get("button2", "app")))
        self.eraser = MOUSE.get(str(actions.get("eraser", "app")))
        self.fd = None
        self.eraser_near = False
        self.pressed = {}

    def wanted(self):
        return any((self.button1, self.button2, self.eraser))

    def open(self):
        if self.fd is None:
            self.fd = os.open(self.node, os.O_RDONLY | os.O_NONBLOCK)
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


def run(plan):
    tablets = [Tablet(spec) for spec in plan.get("tablets", [])]
    tablets = [t for t in tablets if t.wanted() and t.node]
    if not tablets:
        print("nothing to do: no pen button actions configured", file=sys.stderr)
        return 0
    ui = open_uinput()
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
        fcntl.ioctl(ui, UI_DEV_DESTROY)
        os.close(ui)
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 64
    if argv[1] == "--check":
        return check()
    try:
        plan = json.loads(argv[1])
    except ValueError as error:
        print(f"bad plan: {error}", file=sys.stderr)
        return 64
    return run(plan)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
