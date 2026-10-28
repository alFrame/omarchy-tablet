"""Lock the pen to the window of a chosen app.

Runs inside the tablet-buttons service. When "areaLock" is on in
~/.config/omarchy/tablet.json and the focused window's class is listed in
"apps", the pen is mapped onto that window (Hyprland's region_position /
region_size) using the largest centred part of the tablet with the window's
aspect ratio, so circles stay round. When focus moves to any other window the
pen goes back to the normal mapping from tablet.lua.

Hyprland tells us about focus, moves, fullscreen and closed windows over its
event socket, so nothing is polled while the pen is free. It sends no event
for a resize, so while locked the window is re-read twice a second.
"""
import asyncio
import glob
import json
import os
import sys

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".config/omarchy/tablet.json")
CTL = os.path.join(os.path.dirname(os.path.realpath(__file__)), "tablet-ctl")

POLL = 0.5   # seconds between window checks while locked
IDLE = 2.0   # seconds between settings-file checks while free
EVENTS = {"activewindowv2", "closewindow", "fullscreen", "movewindowv2", "workspacev2",
          "focusedmonv2", "changefloatingmode", "configreloaded"}


def log(*args):
    print("area:", *args, file=sys.stderr, flush=True)


def socket_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if signature:
        return f"{runtime}/hypr/{signature}/.socket2.sock"
    found = sorted(glob.glob(f"{runtime}/hypr/*/.socket2.sock"), key=os.path.getmtime)
    return found[-1] if found else None


async def run_cmd(*args, timeout=5):
    """Stdout of a command, or "" when it fails or times out."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        return out.decode(errors="replace")
    except (OSError, asyncio.TimeoutError):
        return ""


class AreaLock:
    def __init__(self):
        self.rect = None        # what the pen is locked to now, None = free
        self.dirty = asyncio.Event()
        self.mtime = None

    def settings(self):
        """(enabled, app classes, pen device, tablet size in mm) from tablet.json."""
        try:
            with open(STATE) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return False, set(), None, None
        last = data.get("lastDevice") or {}
        apps = {k for k, v in (data.get("apps") or {}).items()
                if isinstance(v, dict) and v.get("mode", "window") == "window"}
        size = last.get("sizeMm")
        enabled = data.get("areaLock") is True and bool(apps) and bool(last.get("pen")) and bool(size)
        # A quarter-turn tablet is not handled yet.
        if data.get("rotation", 0) in (90, 270):
            enabled = False
        return enabled, apps, last.get("pen"), size

    @staticmethod
    def target(window, size):
        """Window rectangle plus the matching centred part of the tablet, in mm."""
        x, y = window["at"]
        w, h = window["size"]
        tw, th = size
        if w <= 0 or h <= 0:
            return None
        if w / h > tw / th:
            aw, ah = tw, tw * h / w
        else:
            aw, ah = th * w / h, th
        return (x, y, w, h, round(aw, 2), round(ah, 2), round((tw - aw) / 2, 2), round((th - ah) / 2, 2))

    async def evaluate(self):
        enabled, apps, pen, size = self.settings()
        want = None
        if enabled:
            try:
                window = json.loads(await run_cmd("hyprctl", "activewindow", "-j") or "{}")
            except ValueError:
                window = {}
            if window.get("class") in apps and window.get("mapped", True):
                want = self.target(window, size)
        if want == self.rect:
            return
        if want:
            await self.apply(pen, {
                "active_area_size": f"{want[4]} {want[5]}",
                "active_area_position": f"{want[6]} {want[7]}",
                "region_position": f"{want[0]} {want[1]}",
                "region_size": f"{want[2]} {want[3]}",
                "absolute_region_position": "true",
            })
            if self.rect is None:
                log("locked to", window.get("class"))
        else:
            await self.release(pen)
        self.rect = want

    async def apply(self, pen, options):
        body = ", ".join(f'{k} = {v}' if v in ("true", "false") else f'{k} = "{v}"'
                         for k, v in options.items())
        for name in (pen, pen + "-remap"):  # tablet-buttons' clone while a pen button is remapped
            await run_cmd("hyprctl", "eval", f'hl.device({{ name = "{name}", {body} }})')

    async def release(self, pen=None):
        """Back to the mapping tablet.lua describes, without reloading Hyprland."""
        if self.rect is None:
            return
        pen = pen or self.settings()[2]
        if not pen:
            return
        area = {}
        try:
            area = json.loads(await run_cmd(sys.executable, CTL, "status", timeout=10)).get("area") or {}
        except ValueError:
            pass
        options = {
            "active_area_size": f'{area.get("w", 0)} {area.get("h", 0)}',
            "active_area_position": f'{area.get("x", 0)} {area.get("y", 0)}',
            "region_position": "0 0",
            "region_size": "0 0",
            "absolute_region_position": "false",
        }
        await self.apply(pen, options)
        self.rect = None
        log("released")

    async def listen(self):
        while True:
            path = socket_path()
            try:
                if path:
                    reader, _ = await asyncio.open_unix_connection(path)
                    self.dirty.set()
                    while line := await reader.readline():
                        if line.split(b">>", 1)[0].decode(errors="ignore") in EVENTS:
                            if line.startswith(b"configreloaded"):
                                self.rect = None  # the reload dropped our override; apply it again
                            self.dirty.set()
            except (OSError, ValueError):
                pass
            await asyncio.sleep(2)

    async def run(self):
        listener = asyncio.create_task(self.listen())
        self.dirty.set()
        try:
            while True:
                timed_out = False
                try:
                    await asyncio.wait_for(self.dirty.wait(), POLL if self.rect else IDLE)
                except asyncio.TimeoutError:
                    timed_out = True
                self.dirty.clear()
                if timed_out and not self.rect:
                    try:
                        mtime = os.stat(STATE).st_mtime
                    except OSError:
                        mtime = 0
                    if mtime == self.mtime:
                        continue
                    self.mtime = mtime
                await self.evaluate()
        finally:
            listener.cancel()
            await self.release()
