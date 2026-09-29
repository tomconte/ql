#!/usr/bin/env python3
"""qlshot - look inside a running Q-emuLator: screenshots and memory peeks.

Reads the emulated QL straight out of the Q-emuLator process (read-only
ReadProcessMemory), so it works whatever the display does - HDR, Direct3D,
a covered or minimised window - and returns exact pixels and exact
values:

    python ../tools/qlshot.py run glider.qlpak --wait 3 -o shot.png --close
    python ../tools/qlshot.py shot -o shot.png          # running emulator
    python ../tools/qlshot.py peek headroom+12:w kbd_cur:b '$28034:b'
    python ../tools/qlshot.py info
    python ../tools/qlshot.py close

run      closes any running Q-emuLator (it locks the .qlpak), launches the
         package, waits, then takes the shot and the peeks; --close ends
         the emulator afterwards, which also writes its log
         (%LOCALAPPDATA%\\QemuLator\\qemulator.log).
shot     writes a PNG of the displayed screen (--screen 0/1/both to pick).
peek     prints memory: EXPR[:SIZE][*COUNT], SIZE b/w/l (s prefix =
         signed, default w), EXPR a label, $hex, 0xhex or decimal with
         optional +/- offsets.  Labels come from <name>.lst (the vasm
         listing `make` writes) and are relocated to where QDOS loaded
         <name>_bin, which is found by searching RAM for its first bytes.
info     prints what qlshot knows: memory block, displayed screen, mode,
         program load address.

How it finds things (verified on Q-emuLator 4.0.4, 32-bit):
- The QL address space is one flat, big-endian block in the emulator's
  heap: QL address 0 (the ROM) at the start of a private RW allocation of
  RAM top + 4K.  Found by matching the block's first bytes against the ROM
  images in the emulator's "QL ROMs" dir.  The I/O area is not mirrored
  there ($18063 reads 0).
- The display state lives in QemuLator.exe's static data (fixed image
  base $400000): EMU_STATICS below.  Each entry is trusted only when its
  QL-memory pointer equals the block found above, so another emulator
  build falls back to: QDOS sysvars when $28000 holds $D254 (screen 0,
  mode from sv_mcsta), else both screens and --mode.
Windows only, stdlib only (ctypes).  No writes to the emulator process.
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import os
import re
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

QEMU_DIR = Path(r"C:\Program Files (x86)\QemuLator\QemuLator 4")
QEMU_EXE = QEMU_DIR / "QemuLator.exe"
ROM_DIR = QEMU_DIR / "QL ROMs"
QEMU_LOG = Path(os.environ.get("LOCALAPPDATA", "")) / "QemuLator" / "qemulator.log"

SCREEN = (0x20000, 0x28000)       # screen 0 / screen 1 (ZX8301 base select)
SCR_LEN = 0x8000
SV_IDENT, SV_MCSTA = 0x28000, 0x28034   # Minerva inc/sv: sv_ident, sv_mcsta
SV_IDENT_VAL = 0xD254

# QemuLator.exe statics, per build.  mem_ptr = pointer to the QL memory
# block (validates the entry), scr_base = long, QL address of the
# displayed screen ($20000/$28000), mode8 = byte, nonzero in mode 8.
# 4.0.4: found by diffing the exe's data under flip8/game8/flip/hello,
# then checked against sv_mcsta and the programs' own flips.
EMU_STATICS = [
    dict(build="4.0.4", mem_ptr=0x671E08, scr_base=0x6648D0, mode8=0x671526),
]

# QL colours, index = G*4 + R*2 + B (mode 8; mode 4 uses 0/2/4/7)
PALETTE = [(0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
           (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255)]

# ---------------------------------------------------------------- Windows API
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32 = ctypes.WinDLL("user32", use_last_error=True)

PROCESS_TERMINATE = 0x0001
PROCESS_VM_READ = 0x0010
PROCESS_QUERY_INFORMATION = 0x0400
MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE = 0x1000, 0x20000, 0x04
WM_CLOSE = 0x0010


class MBI(ctypes.Structure):      # MEMORY_BASIC_INFORMATION, 64-bit layout
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", wt.DWORD), ("PartitionId", wt.WORD),
                ("RegionSize", ctypes.c_size_t), ("State", wt.DWORD),
                ("Protect", wt.DWORD), ("Type", wt.DWORD)]


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD),
                ("th32ProcessID", wt.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", wt.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


k32.OpenProcess.restype = wt.HANDLE
k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
k32.CloseHandle.argtypes = [wt.HANDLE]
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                  ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
k32.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
k32.Process32FirstW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
k32.Process32NextW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
k32.GetProcessTimes.argtypes = [wt.HANDLE] + [ctypes.POINTER(ctypes.c_ulonglong)] * 4
k32.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]
WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
u32.EnumWindows.argtypes = [WNDENUMPROC, wt.LPARAM]
u32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
u32.IsWindowVisible.argtypes = [wt.HWND]
u32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]


def die(msg):
    sys.exit(f"qlshot: {msg}")


def emulator_pids():
    """PIDs of running QemuLator.exe processes, newest first."""
    snap = k32.CreateToolhelp32Snapshot(0x2, 0)        # TH32CS_SNAPPROCESS
    pe = PROCESSENTRY32W()
    pe.dwSize = ctypes.sizeof(pe)
    pids = []
    ok = k32.Process32FirstW(snap, ctypes.byref(pe))
    while ok:
        if pe.szExeFile.lower() == QEMU_EXE.name.lower():
            pids.append(pe.th32ProcessID)
        ok = k32.Process32NextW(snap, ctypes.byref(pe))
    k32.CloseHandle(snap)

    def started(pid):
        h = k32.OpenProcess(PROCESS_QUERY_INFORMATION, False, pid)
        t = [ctypes.c_ulonglong() for _ in range(4)]
        k32.GetProcessTimes(h, *(ctypes.byref(x) for x in t))
        k32.CloseHandle(h)
        return t[0].value
    return sorted(pids, key=started, reverse=True)


def rom_heads():
    """First 64 bytes of every ROM image Q-emuLator ships."""
    heads = set()
    for f in ROM_DIR.iterdir():
        if f.is_file() and f.stat().st_size >= 0x4000:
            heads.add(f.read_bytes()[:64])
    return heads


class Emu:
    """A running Q-emuLator, opened read-only."""

    def __init__(self, pid):
        self.pid = pid
        self.h = k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
        if not self.h:
            die(f"cannot open QemuLator.exe (pid {pid}), error {ctypes.get_last_error()}")
        self.base, self.size = self._find_block()
        self.ramtop = self.size & ~0xFFFF
        self.statics = None
        for st in EMU_STATICS:
            if self.host_long(st["mem_ptr"]) == self.base:
                self.statics = st
                break

    def host_read(self, addr, n):
        buf = ctypes.create_string_buffer(n)
        got = ctypes.c_size_t()
        if not k32.ReadProcessMemory(self.h, ctypes.c_void_p(addr), buf, n, ctypes.byref(got)):
            return None
        return buf.raw[:got.value]

    def host_long(self, addr):
        d = self.host_read(addr, 4)
        return struct.unpack("<I", d)[0] if d and len(d) == 4 else None

    def read(self, ql_addr, n):
        if ql_addr < 0 or ql_addr + n > self.size:
            die(f"QL address ${ql_addr:x}+{n} is outside the memory block (${self.size:x})")
        d = self.host_read(self.base + ql_addr, n)
        if d is None or len(d) != n:
            die(f"read of ${ql_addr:x} failed (emulator gone?)")
        return d

    def _find_block(self):
        heads = rom_heads()
        cands = []
        addr, mbi = 0, MBI()
        while addr < 1 << 32 and k32.VirtualQueryEx(self.h, ctypes.c_void_p(addr),
                                                     ctypes.byref(mbi), ctypes.sizeof(mbi)):
            base, size = mbi.BaseAddress or 0, mbi.RegionSize
            if (mbi.State == MEM_COMMIT and mbi.Type == MEM_PRIVATE
                    and mbi.Protect == PAGE_READWRITE and size >= 0x40000
                    and mbi.AllocationBase == mbi.BaseAddress):
                cands.append((base, size))
                if self.host_read(base, 64) in heads:
                    return base, size
            addr = base + size
        raise LookupError(f"no QL memory block found in pid {self.pid} ({len(cands)} "
                          f"candidate regions; is the ROM one of {ROM_DIR}?)")

    # ------------------------------------------------------------ display state
    def qdos_alive(self):
        return struct.unpack(">H", self.read(SV_IDENT, 2))[0] == SV_IDENT_VAL

    def displayed_screen(self):
        """0, 1 or None (unknown)."""
        if self.statics:
            v = self.host_long(self.statics["scr_base"])
            if v in SCREEN:
                return SCREEN.index(v)
        return 0 if self.qdos_alive() else None

    def mode(self):
        """4, 8 or None (unknown)."""
        if self.statics:
            d = self.host_read(self.statics["mode8"], 1)
            if d:
                return 8 if d[0] else 4
        if self.qdos_alive():
            return 8 if self.read(SV_MCSTA, 1)[0] & 8 else 4
        return None


# ------------------------------------------------------------------ rendering
def decode(scr, mode):
    """32K of screen memory -> 256 rows of 512 (r,g,b) pixels (mode 8
    pixels are doubled horizontally)."""
    rows = []
    for y in range(256):
        row = []
        for i in range(y * 128, y * 128 + 128, 2):
            g, r = scr[i], scr[i + 1]
            if mode == 4:       # 8 pixels: G7..G0 / R7..R0, bit 7 leftmost
                for b in range(7, -1, -1):
                    gb, rb = (g >> b) & 1, (r >> b) & 1
                    row.append(PALETTE[gb * 4 + rb * 2 + (gb & rb)])
            else:               # 4 pixels: G3 F3 .. G0 F0 / R3 B3 .. R0 B0
                for s in (7, 5, 3, 1):
                    c = PALETTE[((g >> s) & 1) * 4 + ((r >> s) & 1) * 2 + ((r >> (s - 1)) & 1)]
                    row += (c, c)
        rows.append(row)
    return rows


def write_png(path, rows, yscale=2):
    w, h = len(rows[0]), len(rows) * yscale
    raw = bytearray()
    for row in rows:
        line = b"\x00" + b"".join(bytes(c) for c in row)
        raw += line * yscale

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data)))
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n"
                           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
                           + chunk(b"IEND", b""))


def shot(emu, out, screen="auto", mode="auto"):
    scr = emu.displayed_screen() if screen == "auto" else screen
    md = emu.mode() if mode == "auto" else int(mode)
    notes = []
    if md is None:
        md = 4
        notes.append("mode unknown, assumed 4 (pass --mode)")
    if scr is None or scr == "both":
        if scr is None:
            notes.append("displayed screen unknown, showing both (0 top, 1 bottom)")
        grey = [(128, 128, 128)] * 512
        rows = decode(emu.read(SCREEN[0], SCR_LEN), md) + [grey, grey] \
            + decode(emu.read(SCREEN[1], SCR_LEN), md)
        label = "screens 0+1"
    else:
        rows = decode(emu.read(SCREEN[int(scr)], SCR_LEN), md)
        label = f"screen {scr}"
    write_png(out, rows)
    print(f"{out}: {label}, mode {md}" + "".join(f"; {n}" for n in notes))


# -------------------------------------------------------------------- symbols
def load_symbols(lst):
    """label -> (kind, value) from a vasm listing's "Symbols by name"
    table: kind E = equate (absolute), a section letter (A) = offset in
    <name>_bin.  Local .labels are not listed."""
    syms = {}
    if not lst.exists():
        return syms
    in_table = False
    for line in lst.read_text(errors="replace").splitlines():
        if line.startswith("Symbols by name:"):
            in_table = True
            continue
        if in_table:
            m = re.match(r"^(\S+)\s+([A-Z]):([0-9A-Fa-f]+)\s*$", line)
            if m:
                syms[m.group(1)] = (m.group(2), int(m.group(3), 16))
            elif line.strip() and not line.startswith(" "):
                if syms:
                    break
    return syms


def load_base(emu, binary):
    """QL address where QDOS loaded <name>_bin, or None."""
    if not binary.exists():
        return None
    key = binary.read_bytes()[:64]
    ram = emu.read(0x20000, emu.ramtop - 0x20000)
    hits = [m.start() for m in re.finditer(re.escape(key), ram)]
    # QDOS slave blocks can hold a cached copy of the file's first block;
    # jobs load at the top of the transient area, above them: take the
    # highest hit (agrees with the log's "Loaded ... from" for glider)
    return 0x20000 + hits[-1] if hits else None


class Resolver:
    def __init__(self, emu, name):
        self.emu, self.name = emu, name
        self.syms = load_symbols(Path(f"{name}.lst")) if name else {}
        self._base = False

    def base(self):
        if self._base is False:
            self._base = load_base(self.emu, Path(f"{self.name}_bin")) if self.name else None
        return self._base

    def term(self, t):
        t = t.strip()
        if t.startswith("$"):
            return int(t[1:], 16)
        if re.fullmatch(r"0x[0-9a-fA-F]+|\d+", t):
            return int(t, 0)
        if t not in self.syms:
            die(f"unknown label '{t}' (need {self.name}.lst from `make`)" if self.name
                else f"unknown label '{t}' (run from a project dir or pass --name)")
        kind, val = self.syms[t]
        if kind == "E":          # equate: a number, not an address in the binary
            return val
        b = self.base()
        if b is None:
            die(f"{self.name}_bin not found in QL RAM (not loaded yet?)")
        return b + val

    def expr(self, e):
        parts = re.split(r"([+-])", e)
        v, sign = 0, 1
        for p in parts:
            if p == "+":
                sign = 1
            elif p == "-":
                sign = -1
            elif p.strip():
                v += sign * self.term(p)
        return v


def peek(emu, res, spec):
    m = re.fullmatch(r"(.+?)(?::(s?)([bwl]))?(?:\*(\d+))?", spec)
    if not m:
        die(f"bad peek '{spec}'")
    expr, signed, size, count = m.group(1), m.group(2) == "s", m.group(3) or "w", int(m.group(4) or 1)
    if not m.group(3) and res.syms.get(expr, ("",))[0] == "E":
        v = res.syms[expr][1]
        print(f"{expr} = {v} (${v:x}), an equate; add :b/:w/:l to read memory there")
        return
    addr = res.expr(expr)
    n = {"b": 1, "w": 2, "l": 4}[size]
    fmt = {"b": "b", "w": "h", "l": "i"}[size]
    data = emu.read(addr, n * count)
    vals = struct.unpack(">" + (fmt if signed else fmt.upper()) * count, data)
    hexs = " ".join(data[i * n:(i + 1) * n].hex() for i in range(count))
    print(f"{expr} (${addr:05x}).{size}: {' '.join(str(v) for v in vals)}  [${hexs}]")


# ------------------------------------------------------------ process control
def windows_of(pid):
    found = []

    @WNDENUMPROC
    def cb(hwnd, _):
        p = wt.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and u32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True
    u32.EnumWindows(cb, 0)
    return found


def close_all(timeout=5.0):
    """WM_CLOSE every Q-emuLator (clean exit, writes the log); terminate
    stragglers after the timeout."""
    pids = emulator_pids()
    for pid in pids:
        for hwnd in windows_of(pid):
            u32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
    t_end = time.time() + timeout
    while emulator_pids() and time.time() < t_end:
        time.sleep(0.1)
    for pid in emulator_pids():
        h = k32.OpenProcess(PROCESS_TERMINATE, False, pid)
        k32.TerminateProcess(h, 1)
        k32.CloseHandle(h)
        print(f"qlshot: terminated pid {pid} (no clean exit)")
    return len(pids)


def open_emu(wait=0.0):
    """The newest Q-emuLator; with wait, retry until its QL memory exists."""
    t_end = time.time() + wait
    while True:
        pids = emulator_pids()
        err = "Q-emuLator is not running"
        if pids:
            try:
                return Emu(pids[0])
            except LookupError as e:
                err = str(e)
        if time.time() >= t_end:
            die(err)
        time.sleep(0.2)


def project_name(args, package=None):
    if args.name:
        return args.name
    if package:
        return Path(package).stem.removesuffix("_mdv")    # glider_mdv.QCF
    return Path.cwd().name


# ----------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--name", help="program name for labels (default: the "
                    "package stem, else the current dir name)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def shot_opts(p, default_out=None):
        p.add_argument("-o", "--out", default=default_out, help="PNG to write")
        p.add_argument("--screen", default="auto", choices=["auto", "0", "1", "both"])
        p.add_argument("--mode", default="auto", choices=["auto", "4", "8"])

    p = sub.add_parser("run", help="launch a package, wait, shoot and peek")
    p.add_argument("package")
    p.add_argument("--wait", type=float, default=3.0, help="seconds after launch")
    p.add_argument("--peek", nargs="+", default=[], metavar="SPEC")
    p.add_argument("--close", action="store_true", help="close the emulator afterwards")
    shot_opts(p, default_out="qlshot.png")
    p = sub.add_parser("shot", help="PNG of the displayed screen")
    shot_opts(p, default_out="qlshot.png")
    p = sub.add_parser("peek", help="print memory")
    p.add_argument("spec", nargs="+")
    sub.add_parser("info", help="show emulator / program state")
    sub.add_parser("close", help="close every running Q-emuLator")
    args = ap.parse_args()

    if sys.maxsize < 2 ** 32:
        die("needs a 64-bit Python")

    if args.cmd == "close":
        n = close_all()
        print(f"closed {n} Q-emuLator instance(s)")
        return
    if args.cmd == "run":
        pkg = Path(args.package).resolve()
        if not pkg.exists():
            die(f"{pkg} not found")
        if close_all():
            time.sleep(0.3)
        t0 = time.time()
        subprocess.Popen([str(QEMU_EXE), pkg.name], cwd=pkg.parent)
        emu = open_emu(wait=10.0)
        time.sleep(max(0.0, args.wait - (time.time() - t0)))
        res = Resolver(emu, project_name(args, pkg))
        shot(emu, args.out, args.screen, args.mode)
        for spec in args.peek:
            peek(emu, res, spec)
        if args.close:
            close_all()
        return

    emu = open_emu()
    if args.cmd == "shot":
        shot(emu, args.out, args.screen, args.mode)
    elif args.cmd == "peek":
        res = Resolver(emu, project_name(args))
        for spec in args.spec:
            peek(emu, res, spec)
    elif args.cmd == "info":
        name = project_name(args)
        lb = load_base(emu, Path(f"{name}_bin"))
        scr, md = emu.displayed_screen(), emu.mode()
        print(f"pid {emu.pid}; QL memory at host ${emu.base:08x}, RAM top ${emu.ramtop:x}")
        print(f"emulator statics: {emu.statics['build'] if emu.statics else 'unknown build'}")
        print(f"QDOS sysvars: {'present' if emu.qdos_alive() else 'gone (takeover)'}")
        print(f"displayed screen: {scr if scr is not None else 'unknown'}; "
              f"mode: {md if md is not None else 'unknown'}")
        print(f"{name}_bin: " + (f"loaded at ${lb:05x}" if lb is not None else "not found in RAM"))


if __name__ == "__main__":
    main()
