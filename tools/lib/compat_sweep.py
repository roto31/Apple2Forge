"""Boot every library title headless on the Apple II+ and the Apple //e; record which it needs.

Usage: python3 -I tools/lib/compat_sweep.py --library DIR --emulator PATH --rom-dir DIR
                                            [--frames N] [--jobs N] [--limit N]
Writes DIR/compat.json: {"results": {boot_sha256: {"requirement", "detail", "iiplus", "iie"}}}.
library_catalog.py reads it on the next catalog build. Exit 2 on bad input.

A boot is judged from the machine state after --frames frames (60 per second):
it failed if the CPU is still in the Disk II boot ROM, met an opcode the CPU
does not have, left an error, a machine-requirement message or a bare
BASIC/monitor prompt on the text screen, or shows an empty screen. Anything
else counts as booted. Empty screens are retried for SLOW_LOAD_FRAMES.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass

REQUIREMENT_IIPLUS = "IIplus64K"
REQUIREMENT_IIE = "IIe128K"
REQUIREMENT_NOBOOT = "noboot"
REQUIREMENT_UNKNOWN = "unknown"

DEFAULT_FRAMES = 1800
# Slow loaders are still reading the disk with the screen blank at DEFAULT_FRAMES.
SLOW_LOAD_FRAMES = 7200
EMULATOR_TIMEOUT_SECONDS = 60
BOOT_ROM_PAGE = 0xC6
TEXT_ROWS = 24
TEXT_COLUMNS = 40
INVALID_OPCODE = re.compile(r"Invalid instruction \$([0-9A-F]{2})")
NEEDS_IIE_TEXT = re.compile(r"128K|APPLE ?//? ?E|APPLE IIE|ENHANCED|65C02|80.COLUMN|REQUIRES", re.I)
ERROR_TEXT = re.compile(r"ERROR|UNABLE TO|NOT AVAILABLE|BREAK IN|NO BUFFERS|FILE NOT FOUND", re.I)
BARE_PROMPTS = {"]", "*", ">"}
MONITOR_BREAK = re.compile(r"^([0-9A-F]{4})-\s+A=")
CURSOR_CHARACTERS = "`\x7f "
BLANK_SCREEN = "blank text screen"
BLANK_GRAPHICS = "blank graphics screen"
# (page 1 address, page size) of each full-screen graphics mode.
GRAPHICS_PAGES = {"gr": (0x400, 0x400), "hgr": (0x2000, 0x2000)}
HGR_DATA_BITS = 0x7F
IIE_HINT = re.compile(r"128k|//e|\biie\b|\benhanced\b|65c02|80[ -]?col|double hi-?res", re.I)


@dataclass
class Boot:
    booted: bool
    detail: str
    no_boot_sector: bool = False

    def as_dict(self) -> dict:
        return {"booted": self.booted, "detail": self.detail}


def screen_char(byte: int) -> str:
    code = byte & 0x7F
    if code < 0x20:
        code += 0x40
    return chr(code)


def text_rows(main: bytes, aux: bytes | None) -> list[str]:
    """Text page 1; 80 columns (aux and main interleaved) when aux is given."""
    rows = []
    for row in range(TEXT_ROWS):
        offset = 0x400 + (row % 8) * 0x80 + (row // 8) * TEXT_COLUMNS
        if aux is None:
            line = "".join(screen_char(b) for b in main[offset:offset + TEXT_COLUMNS])
        else:
            line = "".join(screen_char(aux[offset + i]) + screen_char(main[offset + i])
                           for i in range(TEXT_COLUMNS))
        rows.append(line.rstrip(CURSOR_CHARACTERS))
    return [r for r in rows if r.strip()]


def graphics_page_blank(regs: dict[str, str], main: bytes, aux: bytes | None) -> bool:
    """True when the displayed full-screen graphics page is all black in main (and aux) memory."""
    mode = regs["vidmode"].strip()
    if mode not in GRAPHICS_PAGES or regs.get("mixed", "0").strip() == "1":
        return False
    first_page, size = GRAPHICS_PAGES[mode]
    start = first_page + (int(regs.get("vidpage", "1")) - 1) * size
    mask = HGR_DATA_BITS if mode == "hgr" else 0xFF
    return all(not (b & mask) for memory in (main, aux) if memory for b in memory[start:start + size])


def read_regs(path: str) -> dict[str, str]:
    with open(path) as handle:
        return dict(line.split(" ", 1) for line in handle.read().splitlines() if " " in line)


def judge(regs: dict[str, str], rows: list[str], log: str, cmos: bool,
          graphics_blank: bool = False) -> Boot:
    pc = int(regs["pc"], 16)
    text_mode = regs["vidmode"].strip() == "text"
    if pc >> 8 == BOOT_ROM_PAGE:
        return Boot(False, "still in the Disk II boot ROM: no readable boot sector", no_boot_sector=True)
    invalid = INVALID_OPCODE.search(log)
    if invalid and not cmos:
        return Boot(False, f"ran opcode ${invalid.group(1)}, which only a 65C02 has")
    if invalid:
        return Boot(False, f"ran invalid opcode ${invalid.group(1)}")
    if not text_mode and graphics_blank:
        return Boot(False, BLANK_GRAPHICS)
    if not text_mode:
        return Boot(True, f"{regs['vidmode'].strip()} graphics")
    if not rows:
        return Boot(False, BLANK_SCREEN)
    for line in rows:
        if NEEDS_IIE_TEXT.search(line) and not cmos:
            return Boot(False, f"screen says: {line.strip()}")
        if ERROR_TEXT.search(line):
            return Boot(False, f"screen says: {line.strip()}")
    if rows[-1].strip() in BARE_PROMPTS:
        crash = MONITOR_BREAK.match(rows[-2].strip()) if len(rows) > 1 else None
        if crash:
            return Boot(False, f"crashed into the monitor at ${crash.group(1)}")
        before = rows[-2].strip() if len(rows) > 1 else ""
        return Boot(False, f"stopped at a {rows[-1].strip()} prompt" + (f" after: {before}" if before else ""))
    return Boot(True, f"text: {rows[0].strip()[:60]}")


def run_boot(args: argparse.Namespace, model: str, drive1: str, drive2: str | None) -> Boot:
    boot = run_boot_for(args, model, drive1, drive2, args.frames)
    if not boot.booted and boot.detail in (BLANK_SCREEN, BLANK_GRAPHICS):
        boot = run_boot_for(args, model, drive1, drive2, max(args.frames, SLOW_LOAD_FRAMES))
    return boot


def run_boot_for(args: argparse.Namespace, model: str, drive1: str, drive2: str | None,
                 frames: int) -> Boot:
    with tempfile.TemporaryDirectory(prefix="a2compat-") as work:
        snapshot = os.path.join(work, "s")
        command = [args.emulator, "--headless", "--no-sound", f"--frames={frames}",
                   f"--snapshot-frame={frames}", f"--snapshot-out={snapshot}",
                   f"--disk1={drive1}"]
        if drive2:
            command.append(f"--disk2={drive2}")
        if model == "iie":
            command += ["--model=iie", f"--rom={args.rom_dir}/apple2e-enhanced.rom",
                        f"--video-rom={args.rom_dir}/apple2e-video.rom"]
        else:
            command.append(f"--rom={args.rom_dir}/apple2plus.rom")
        try:
            result = subprocess.run(command, capture_output=True, text=True, errors="replace",
                                    timeout=EMULATOR_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            return Boot(False, f"emulator ran past {EMULATOR_TIMEOUT_SECONDS}s")
        if result.returncode != 0 or not os.path.isfile(snapshot + ".regs"):
            last = (result.stderr.strip().splitlines() or ["no output"])[-1]
            return Boot(False, f"emulator exit {result.returncode}: {last[:120]}")
        regs = read_regs(snapshot + ".regs")
        if model == "iie":
            main = open(snapshot + ".main", "rb").read()
            aux = open(snapshot + ".aux", "rb").read()
            col80 = "80COL 1" in open(snapshot + ".iie").read().splitlines()
            rows = text_rows(main, aux if col80 else None)
        else:
            main, aux = open(snapshot, "rb").read(), None
            rows = text_rows(main, None)
        return judge(regs, rows, result.stdout + result.stderr, cmos=(model == "iie"),
                     graphics_blank=graphics_page_blank(regs, main, aux))


def classify(args: argparse.Namespace, title: dict) -> dict:
    disks = os.path.join(args.library, "disks")
    drive1 = os.path.join(disks, title["boot"]["drive1"])
    drive2 = os.path.join(disks, title["boot"]["drive2"]) if title["boot"]["drive2"] else None
    names_iie = bool(IIE_HINT.search(" ".join([title["title"]] + title["notes"]
                                              + [s["file"] for d in title["disks"] for s in d["sides"]])))
    plus = run_boot(args, "iiplus", drive1, drive2)
    record = {"iiplus": plus.as_dict()}
    if plus.booted and not names_iie:
        return {**record, "requirement": REQUIREMENT_IIPLUS, "detail": f"boots on the II+ ({plus.detail})"}
    iie = run_boot(args, "iie", drive1, drive2)
    record["iie"] = iie.as_dict()
    if iie.booted and not plus.booted:
        return {**record, "requirement": REQUIREMENT_IIE, "detail": f"II+: {plus.detail}; //e: {iie.detail}"}
    if iie.booted:
        return {**record, "requirement": REQUIREMENT_IIE,
                "detail": "boots on both; the title or file name names the //e"}
    if plus.booted:
        return {**record, "requirement": REQUIREMENT_IIPLUS,
                "detail": f"boots on the II+ ({plus.detail}); //e: {iie.detail}"}
    if plus.no_boot_sector and iie.no_boot_sector:
        return {**record, "requirement": REQUIREMENT_NOBOOT, "detail": plus.detail}
    return {**record, "requirement": REQUIREMENT_UNKNOWN,
            "detail": f"did not boot. II+: {plus.detail}; //e: {iie.detail}"}


def file_sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--library", required=True)
    parser.add_argument("--emulator", required=True)
    parser.add_argument("--rom-dir", required=True)
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--limit", type=int, default=0, help="sweep only the first N titles")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    catalog_path = os.path.join(args.library, "library.json")
    if not os.path.isfile(catalog_path):
        print(f"ERROR: no {catalog_path}; run tools/50_library.sh first", file=sys.stderr)
        return 2
    with open(catalog_path) as handle:
        titles = json.load(handle)["titles"]
    boot_disks: dict[str, dict] = {}
    for title in titles:
        boot_disks.setdefault(title["disks"][0]["sides"][0]["sha256"], title)
    work = list(boot_disks.items())[:args.limit or None]

    results: dict[str, dict] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(classify, args, title): sha for sha, title in work}
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            results[futures[future]] = future.result()
            if done % 100 == 0 or done == len(work):
                print(f"swept {done}/{len(work)}", flush=True)

    counts: dict[str, int] = {}
    for record in results.values():
        counts[record["requirement"]] = counts.get(record["requirement"], 0) + 1
    output = {
        "schemaVersion": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "frames": args.frames,
        "emulatorSha256": file_sha256(args.emulator),
        "counts": counts,
        "results": dict(sorted(results.items())),
    }
    temporary = os.path.join(args.library, "compat.json.tmp")
    with open(temporary, "w") as handle:
        json.dump(output, handle, indent=1)
    os.replace(temporary, os.path.join(args.library, "compat.json"))
    print(json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
