#!/usr/bin/env python3
"""Stage 1: analyze an Apple II 5.25-inch disk image, read-only.

Usage: python3 -I tools/10_analyze.py IMAGE [--out DIR]

Writes DIR/analysis.json and DIR/analysis.md (default DIR: work/<disk-slug>/).
Unsupported inputs (.nib, .woz, .2mg, wrong size) are reported inside the
output rather than raised, so exit code 0 means "analysis written" whatever
the verdict. Exit codes: 0 analysis written, 1 runtime failure, 2 bad arguments.
Standard library only; no third-party packages.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ANALYSIS_SCHEMA_VERSION = 1

SECTOR_SIZE = 256
SECTORS_PER_TRACK = 16
TRACK_COUNT = 35
SECTOR_IMAGE_SIZE = SECTOR_SIZE * SECTORS_PER_TRACK * TRACK_COUNT
NIB_TRACK_SIZE = 6656
NIB_IMAGE_SIZE = NIB_TRACK_SIZE * TRACK_COUNT
MAX_INPUT_SIZE = 1 << 20
BLOCK_SIZE = 512
SECTORS_PER_BLOCK = BLOCK_SIZE // SECTOR_SIZE
BLOCKS_PER_TRACK = SECTORS_PER_TRACK // SECTORS_PER_BLOCK

# Physical sector holding each logical sector, for the two common sector orders.
DOS_LOGICAL_TO_PHYSICAL = (0, 13, 11, 9, 7, 5, 3, 1, 14, 12, 10, 8, 6, 4, 2, 15)
PRODOS_LOGICAL_TO_PHYSICAL = (0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15)

VTOC_TRACK = 17
VTOC_SECTOR = 0
CATALOG_ENTRY_OFFSET = 0x0B
CATALOG_ENTRY_SIZE = 35
CATALOG_ENTRIES_PER_SECTOR = 7
CATALOG_NAME_LENGTH = 30
VTOC_BITMAP_OFFSET = 0x38
VTOC_BITMAP_BYTES_PER_TRACK = 4
UNUSED_CATALOG_ENTRY = 0x00
DELETED_CATALOG_ENTRY = 0xFF
DOS_FILE_LOCKED_BIT = 0x80
TS_LIST_PAIRS_OFFSET = 0x0C

PRODOS_VOLUME_DIRECTORY_BLOCK = 2
PRODOS_ENTRY_LENGTH = 0x27
PRODOS_ENTRIES_PER_BLOCK = 0x0D
PRODOS_VOLUME_HEADER_STORAGE_TYPE = 0xF
PRODOS_DIRECTORY_STORAGE_TYPE = 0xD
MAX_DIRECTORY_BLOCKS = 64

# A catalog that accounts for less than this share of the used sectors points
# at data a loader reads directly from raw tracks.
CATALOG_COVERAGE_THRESHOLD = 0.25

BOOT_LOAD_ADDRESS = 0x0800
BOOT_ENTRY_ADDRESS = 0x0801
# Boot-stage code commonly pulls its next stage in just above the boot sector,
# so jumps into this range are treated as loader code, not the game entry.
LOADER_AREA_END = 0x0BFF
LOWEST_PROGRAM_ADDRESS = 0x0200
IO_START = 0xC000
SOFT_SWITCH_END = 0xC0FF
SLOT_ROM_END = 0xCFFF
UPPER_ROM_START = 0xD000
MONITOR_ROM_START = 0xF800

STANDARD_ADDRESS_PROLOGUE = (0xD5, 0xAA, 0x96)
STANDARD_DATA_PROLOGUE = (0xD5, 0xAA, 0xAD)
STANDARD_EPILOGUE = (0xDE, 0xAA)
# Compares within this many bytes of each other belong to one marker sequence.
MARKER_GROUP_GAP = 0x10
# BPL *-3 (wait for a disk nibble) then CMP #imm: the RWTS "expect this marker" idiom.
READ_MARKER_PATTERN = re.compile(rb"\x10\xFB\xC9(.)", re.DOTALL)
# LDA #imm / JSR write-nibble, three in a row: the RWTS "write this prologue" idiom.
WRITE_PROLOGUE_PATTERN = re.compile(rb"\xA9(.)\x20..\xA9(.)\x20..\xA9(.)\x20..", re.DOTALL)


@dataclass(frozen=True)
class LoaderSignature:
    loader_id: str
    name: str
    boot_prefix: bytes
    custom: bool
    confidence: str


KNOWN_LOADERS = (
    LoaderSignature("dos33", "Apple DOS 3.3", bytes.fromhex("01A527C909"), False, "standard"),
    LoaderSignature("prodos", "ProDOS", bytes.fromhex("0138B003"), False, "standard"),
    LoaderSignature("mecc", "MECC loader", bytes.fromhex("014C1A08"), True, "single-sample"),
)
MECC_CATALOG_HINTS = (re.compile(r"^MECC\$\$DISK$"), re.compile(r"^\[.*/\d{4}\]$"))


@dataclass(frozen=True)
class CrackSignature:
    name: str
    source: str
    # (track, DOS logical sector, byte offset, expected value) after cracking.
    patches: tuple[tuple[int, int, int, int], ...]


KNOWN_CRACKS = (
    CrackSignature(
        name="4am / Passport crack of MECC Number Munchers v1.3 (RWTS prologue patches)",
        source="4am crack No. 2390, Passport transcript, 2021-03-01",
        patches=(
            (0, 0x0B, 0x08, 0xD5),
            (0, 0x0B, 0x12, 0xAA),
            (0, 0x0B, 0x1D, 0x96),
            (0, 0x0B, 0x99, 0xAA),
            (0, 0x0B, 0xA3, 0xAD),
            (0, 0x0C, 0x82, 0xAA),
            (0, 0x0C, 0x87, 0xAD),
        ),
    ),
)

DOS_FILE_TYPES = {
    0x00: ("T", "text"),
    0x01: ("I", "Integer BASIC"),
    0x02: ("A", "Applesoft BASIC"),
    0x04: ("B", "binary"),
    0x08: ("S", "S-type"),
    0x10: ("R", "relocatable"),
    0x20: ("A2", "new A-type"),
    0x40: ("B2", "new B-type"),
}

PRODOS_FILE_TYPES = {
    0x04: "TXT",
    0x06: "BIN",
    0x0F: "DIR",
    0xFA: "INT",
    0xFC: "BAS",
    0xFE: "REL",
    0xFF: "SYS",
}

MONITOR_ROUTINES = {
    0xF800: "PLOT",
    0xF832: "CLRSCR",
    0xF864: "SETCOL",
    0xFA62: "RESET",
    0xFB1E: "PREAD",
    0xFB2F: "INIT",
    0xFC22: "VTAB",
    0xFC58: "HOME",
    0xFCA8: "WAIT",
    0xFD0C: "RDKEY",
    0xFD1B: "KEYIN",
    0xFD6A: "GETLN",
    0xFDED: "COUT",
    0xFDF0: "COUT1",
    0xFE89: "SETKBD",
    0xFE93: "SETVID",
    0xFF2D: "PRERR",
    0xFF3A: "BELL",
    0xFF58: "IORTS",
    0xFF69: "MONZ",
}

SOFT_SWITCHES = {
    0xC000: "KBD: keyboard data",
    0xC010: "KBDSTRB: clear keyboard strobe",
    0xC030: "SPKR: speaker toggle",
    0xC050: "TXTCLR: graphics on",
    0xC051: "TXTSET: text on",
    0xC052: "MIXCLR: full screen",
    0xC053: "MIXSET: mixed text/graphics",
    0xC054: "LOWSCR: display page 1",
    0xC055: "HISCR: display page 2",
    0xC056: "LORES: lo-res graphics",
    0xC057: "HIRES: hi-res graphics",
    0xC061: "PB0: pushbutton 0",
    0xC062: "PB1: pushbutton 1",
    0xC064: "PADDL0: paddle 0",
    0xC065: "PADDL1: paddle 1",
    0xC070: "PTRIG: paddle timer reset",
    0xC080: "language card: read RAM bank 2, write-protect",
    0xC081: "language card: read ROM, write RAM bank 2 (two reads)",
    0xC082: "language card: read ROM, write-protect",
    0xC083: "language card: read/write RAM bank 2 (two reads)",
    0xC088: "language card: read RAM bank 1, write-protect",
    0xC089: "language card: read ROM, write RAM bank 1 (two reads)",
    0xC08A: "language card: read ROM, write-protect",
    0xC08B: "language card: read/write RAM bank 1 (two reads)",
}

# Disk II registers are addressed $C080+slot*16, i.e. indexed by X.
DISK_II_REGISTERS = {
    0x0: "Disk II phase 0 off",
    0x8: "Disk II motor off",
    0x9: "Disk II motor on",
    0xA: "Disk II select drive 1",
    0xB: "Disk II select drive 2",
    0xC: "Disk II Q6L: read data latch",
    0xD: "Disk II Q6H: write protect / load latch",
    0xE: "Disk II Q7L: read mode",
    0xF: "Disk II Q7H: write mode",
}


# ── 6502 disassembler (official NMOS opcodes) ───────────────────────────────

MODE_LENGTHS = {
    "imp": 1, "acc": 1, "imm": 2, "zp": 2, "zpx": 2, "zpy": 2, "izx": 2, "izy": 2,
    "rel": 2, "abs": 3, "abx": 3, "aby": 3, "ind": 3,
}

# The eight "group one" ALU instructions share one mode layout: base opcode + offset.
GROUP_ONE_BASES = {"ORA": 0x00, "AND": 0x20, "EOR": 0x40, "ADC": 0x60, "STA": 0x80, "LDA": 0xA0, "CMP": 0xC0, "SBC": 0xE0}
GROUP_ONE_MODE_OFFSETS = {"izx": 0x01, "zp": 0x05, "imm": 0x09, "abs": 0x0D, "izy": 0x11, "zpx": 0x15, "aby": 0x19, "abx": 0x1D}

OTHER_OPCODES: dict[int, tuple[str, str]] = {
    0x00: ("BRK", "imp"), 0x08: ("PHP", "imp"), 0x18: ("CLC", "imp"), 0x28: ("PLP", "imp"),
    0x38: ("SEC", "imp"), 0x40: ("RTI", "imp"), 0x48: ("PHA", "imp"), 0x58: ("CLI", "imp"),
    0x60: ("RTS", "imp"), 0x68: ("PLA", "imp"), 0x78: ("SEI", "imp"), 0x88: ("DEY", "imp"),
    0x8A: ("TXA", "imp"), 0x98: ("TYA", "imp"), 0x9A: ("TXS", "imp"), 0xA8: ("TAY", "imp"),
    0xAA: ("TAX", "imp"), 0xB8: ("CLV", "imp"), 0xBA: ("TSX", "imp"), 0xC8: ("INY", "imp"),
    0xCA: ("DEX", "imp"), 0xD8: ("CLD", "imp"), 0xE8: ("INX", "imp"), 0xEA: ("NOP", "imp"),
    0xF8: ("SED", "imp"),
    0x10: ("BPL", "rel"), 0x30: ("BMI", "rel"), 0x50: ("BVC", "rel"), 0x70: ("BVS", "rel"),
    0x90: ("BCC", "rel"), 0xB0: ("BCS", "rel"), 0xD0: ("BNE", "rel"), 0xF0: ("BEQ", "rel"),
    0x20: ("JSR", "abs"), 0x4C: ("JMP", "abs"), 0x6C: ("JMP", "ind"),
    0x24: ("BIT", "zp"), 0x2C: ("BIT", "abs"),
    0x0A: ("ASL", "acc"), 0x06: ("ASL", "zp"), 0x16: ("ASL", "zpx"), 0x0E: ("ASL", "abs"), 0x1E: ("ASL", "abx"),
    0x2A: ("ROL", "acc"), 0x26: ("ROL", "zp"), 0x36: ("ROL", "zpx"), 0x2E: ("ROL", "abs"), 0x3E: ("ROL", "abx"),
    0x4A: ("LSR", "acc"), 0x46: ("LSR", "zp"), 0x56: ("LSR", "zpx"), 0x4E: ("LSR", "abs"), 0x5E: ("LSR", "abx"),
    0x6A: ("ROR", "acc"), 0x66: ("ROR", "zp"), 0x76: ("ROR", "zpx"), 0x6E: ("ROR", "abs"), 0x7E: ("ROR", "abx"),
    0xC6: ("DEC", "zp"), 0xD6: ("DEC", "zpx"), 0xCE: ("DEC", "abs"), 0xDE: ("DEC", "abx"),
    0xE6: ("INC", "zp"), 0xF6: ("INC", "zpx"), 0xEE: ("INC", "abs"), 0xFE: ("INC", "abx"),
    0xA2: ("LDX", "imm"), 0xA6: ("LDX", "zp"), 0xB6: ("LDX", "zpy"), 0xAE: ("LDX", "abs"), 0xBE: ("LDX", "aby"),
    0xA0: ("LDY", "imm"), 0xA4: ("LDY", "zp"), 0xB4: ("LDY", "zpx"), 0xAC: ("LDY", "abs"), 0xBC: ("LDY", "abx"),
    0x86: ("STX", "zp"), 0x96: ("STX", "zpy"), 0x8E: ("STX", "abs"),
    0x84: ("STY", "zp"), 0x94: ("STY", "zpx"), 0x8C: ("STY", "abs"),
    0xE0: ("CPX", "imm"), 0xE4: ("CPX", "zp"), 0xEC: ("CPX", "abs"),
    0xC0: ("CPY", "imm"), 0xC4: ("CPY", "zp"), 0xCC: ("CPY", "abs"),
}


def build_opcode_table() -> dict[int, tuple[str, str]]:
    table = dict(OTHER_OPCODES)
    for mnemonic, base in GROUP_ONE_BASES.items():
        for mode, offset in GROUP_ONE_MODE_OFFSETS.items():
            if mnemonic == "STA" and mode == "imm":
                continue
            table[base + offset] = (mnemonic, mode)
    return table


OPCODES = build_opcode_table()


@dataclass(frozen=True)
class Instruction:
    address: int
    raw: bytes
    mnemonic: str
    mode: str
    operand: int | None

    @property
    def branch_target(self) -> int | None:
        if self.mode != "rel" or self.operand is None:
            return None
        displacement = self.operand - 0x100 if self.operand >= 0x80 else self.operand
        return (self.address + 2 + displacement) & 0xFFFF

    def text(self) -> str:
        value = self.operand
        formats = {
            "imp": lambda: self.mnemonic,
            "acc": lambda: f"{self.mnemonic} A",
            "imm": lambda: f"{self.mnemonic} #${value:02X}",
            "zp": lambda: f"{self.mnemonic} ${value:02X}",
            "zpx": lambda: f"{self.mnemonic} ${value:02X},X",
            "zpy": lambda: f"{self.mnemonic} ${value:02X},Y",
            "izx": lambda: f"{self.mnemonic} (${value:02X},X)",
            "izy": lambda: f"{self.mnemonic} (${value:02X}),Y",
            "rel": lambda: f"{self.mnemonic} ${self.branch_target:04X}",
            "abs": lambda: f"{self.mnemonic} ${value:04X}",
            "abx": lambda: f"{self.mnemonic} ${value:04X},X",
            "aby": lambda: f"{self.mnemonic} ${value:04X},Y",
            "ind": lambda: f"{self.mnemonic} (${value:04X})",
        }
        return formats[self.mode]()


def decode_instruction(memory: bytes, base_address: int, address: int) -> Instruction | None:
    """Decode one instruction; None for an unknown opcode or one running past the end."""
    offset = address - base_address
    if offset < 0 or offset >= len(memory):
        return None
    opcode = memory[offset]
    if opcode not in OPCODES:
        return None
    mnemonic, mode = OPCODES[opcode]
    length = MODE_LENGTHS[mode]
    if offset + length > len(memory):
        return None
    raw = memory[offset:offset + length]
    operand = None
    if length == 2:
        operand = raw[1]
    elif length == 3:
        operand = raw[1] | raw[2] << 8
    return Instruction(address, raw, mnemonic, mode, operand)


@dataclass
class BootTrace:
    instructions: dict[int, Instruction] = field(default_factory=dict)
    external_jumps: list[tuple[int, int]] = field(default_factory=list)
    external_calls: list[tuple[int, int]] = field(default_factory=list)
    indirect_jumps: list[tuple[int, int]] = field(default_factory=list)
    stopped_at: list[tuple[int, str]] = field(default_factory=list)


def trace_code(memory: bytes, base_address: int, start_address: int) -> BootTrace:
    """Follow every statically reachable path; never execute anything."""
    trace = BootTrace()
    end_address = base_address + len(memory) - 1
    pending = [start_address]

    def in_region(address: int) -> bool:
        return base_address <= address <= end_address

    while pending:
        address = pending.pop()
        while in_region(address) and address not in trace.instructions:
            instruction = decode_instruction(memory, base_address, address)
            if instruction is None:
                trace.stopped_at.append((address, "unknown opcode or truncated instruction"))
                break
            trace.instructions[address] = instruction
            mnemonic, mode, operand = instruction.mnemonic, instruction.mode, instruction.operand
            if mnemonic == "JMP" and mode == "abs":
                if in_region(operand):
                    pending.append(operand)
                else:
                    trace.external_jumps.append((address, operand))
                break
            if mnemonic == "JMP" and mode == "ind":
                trace.indirect_jumps.append((address, operand))
                break
            if mnemonic in ("RTS", "RTI", "BRK"):
                break
            if mnemonic == "JSR":
                if in_region(operand):
                    pending.append(operand)
                else:
                    trace.external_calls.append((address, operand))
            branch_target = instruction.branch_target
            if branch_target is not None and in_region(branch_target):
                pending.append(branch_target)
            address += len(instruction.raw)
        else:
            if not in_region(address):
                trace.stopped_at.append((address, "ran past the end of the loaded boot code"))
    return trace


# ── Disk image access ───────────────────────────────────────────────────────

@dataclass(frozen=True)
class SectorImage:
    data: bytes
    order: str  # "dos" or "prodos": how 256-byte sectors are laid out in the file

    def physical_sector(self, track: int, physical: int) -> bytes:
        table = DOS_LOGICAL_TO_PHYSICAL if self.order == "dos" else PRODOS_LOGICAL_TO_PHYSICAL
        offset = (track * SECTORS_PER_TRACK + table.index(physical)) * SECTOR_SIZE
        return self.data[offset:offset + SECTOR_SIZE]

    def dos_sector(self, track: int, logical: int) -> bytes:
        return self.physical_sector(track, DOS_LOGICAL_TO_PHYSICAL[logical])

    def prodos_block(self, block: int) -> bytes:
        track = block // BLOCKS_PER_TRACK
        first_half = (block % BLOCKS_PER_TRACK) * SECTORS_PER_BLOCK
        return b"".join(
            self.physical_sector(track, PRODOS_LOGICAL_TO_PHYSICAL[first_half + half])
            for half in range(SECTORS_PER_BLOCK)
        )


def apple_text(raw: bytes) -> str:
    """Decode Apple II high-bit ASCII; control characters shown as ^X."""
    characters = []
    for byte in raw:
        code = byte & 0x7F
        characters.append(f"^{chr(code + 0x40)}" if code < 0x20 else chr(code))
    return "".join(characters)


def parse_dos33(image: SectorImage) -> dict[str, Any] | None:
    vtoc = image.dos_sector(VTOC_TRACK, VTOC_SECTOR)
    catalog_track, catalog_sector = vtoc[1], vtoc[2]
    looks_valid = (
        vtoc[0x35] == SECTORS_PER_TRACK
        and vtoc[0x34] in (TRACK_COUNT, 40)
        and vtoc[0x36] == 0x00
        and vtoc[0x37] == 0x01
        and 0 < catalog_track < TRACK_COUNT
        and catalog_sector < SECTORS_PER_TRACK
    )
    if not looks_valid:
        return None

    entries: list[dict[str, Any]] = []
    visited: set[tuple[int, int]] = set()
    track, sector = catalog_track, catalog_sector
    while 0 < track < TRACK_COUNT and sector < SECTORS_PER_TRACK and (track, sector) not in visited:
        visited.add((track, sector))
        catalog = image.dos_sector(track, sector)
        for index in range(CATALOG_ENTRIES_PER_SECTOR):
            entry = catalog[CATALOG_ENTRY_OFFSET + index * CATALOG_ENTRY_SIZE:][:CATALOG_ENTRY_SIZE]
            if entry[0] in (UNUSED_CATALOG_ENTRY, DELETED_CATALOG_ENTRY):
                continue
            type_byte = entry[2]
            code, description = DOS_FILE_TYPES.get(type_byte & ~DOS_FILE_LOCKED_BIT & 0xFF, (f"${type_byte:02X}", "unknown"))
            entries.append({
                "name": apple_text(entry[3:3 + CATALOG_NAME_LENGTH]).rstrip(),
                "type": code,
                "type_description": description,
                "locked": bool(type_byte & DOS_FILE_LOCKED_BIT),
                "sectors": entry[33] | entry[34] << 8,
                "first_ts_list": [entry[0], entry[1]],
            })
        track, sector = catalog[1], catalog[2]

    valid_ts_lists = sum(
        ts_list_looks_valid(image.dos_sector(*entry["first_ts_list"]))
        for entry in entries
        if entry["first_ts_list"][0] < TRACK_COUNT and entry["first_ts_list"][1] < SECTORS_PER_TRACK
    )

    free_map = {}
    for track_number in range(TRACK_COUNT):
        offset = VTOC_BITMAP_OFFSET + track_number * VTOC_BITMAP_BYTES_PER_TRACK
        free_map[track_number] = vtoc[offset] << 8 | vtoc[offset + 1]
    free_sectors = sum(bin(bits).count("1") for bits in free_map.values())
    return {
        "type": "dos33",
        "volume": vtoc[6],
        "dos_release": vtoc[3],
        "catalog_start": [catalog_track, catalog_sector],
        "catalog": entries,
        "catalog_entry_count": len(entries),
        "catalog_sector_total": sum(entry["sectors"] for entry in entries),
        "total_sectors": TRACK_COUNT * SECTORS_PER_TRACK,
        "free_sectors": free_sectors,
        "_free_map": free_map,
        "_valid_ts_lists": valid_ts_lists,
    }


def ts_list_looks_valid(sector_bytes: bytes) -> bool:
    """A DOS 3.3 track/sector list: in-range link and pairs, at least one data sector."""
    next_track, next_sector = sector_bytes[1], sector_bytes[2]
    pairs = [(sector_bytes[offset], sector_bytes[offset + 1]) for offset in range(TS_LIST_PAIRS_OFFSET, SECTOR_SIZE, 2)]
    return (
        next_track < TRACK_COUNT
        and next_sector < SECTORS_PER_TRACK
        and all(track < TRACK_COUNT and sector < SECTORS_PER_TRACK for track, sector in pairs)
        and any(track for track, _ in pairs)
    )


def parse_prodos(image: SectorImage) -> dict[str, Any] | None:
    key_block = image.prodos_block(PRODOS_VOLUME_DIRECTORY_BLOCK)
    header_byte = key_block[4]
    looks_valid = (
        key_block[0:2] == b"\x00\x00"
        and header_byte >> 4 == PRODOS_VOLUME_HEADER_STORAGE_TYPE
        and header_byte & 0x0F > 0
        and key_block[0x23] == PRODOS_ENTRY_LENGTH
        and key_block[0x24] == PRODOS_ENTRIES_PER_BLOCK
    )
    if not looks_valid:
        return None

    volume_name = key_block[5:5 + (header_byte & 0x0F)].decode("ascii", "replace")
    bitmap_block = key_block[0x27] | key_block[0x28] << 8
    total_blocks = key_block[0x29] | key_block[0x2A] << 8
    entries: list[dict[str, Any]] = []
    visited: set[int] = set()
    block_number = PRODOS_VOLUME_DIRECTORY_BLOCK
    while block_number and block_number not in visited and len(visited) < MAX_DIRECTORY_BLOCKS:
        visited.add(block_number)
        block = image.prodos_block(block_number)
        for index in range(PRODOS_ENTRIES_PER_BLOCK):
            if block_number == PRODOS_VOLUME_DIRECTORY_BLOCK and index == 0:
                continue
            entry = block[4 + index * PRODOS_ENTRY_LENGTH:][:PRODOS_ENTRY_LENGTH]
            storage_type, name_length = entry[0] >> 4, entry[0] & 0x0F
            if storage_type == 0 or name_length == 0:
                continue
            file_type = entry[0x10]
            entries.append({
                "name": entry[1:1 + name_length].decode("ascii", "replace"),
                "type": PRODOS_FILE_TYPES.get(file_type, f"${file_type:02X}"),
                "is_directory": storage_type == PRODOS_DIRECTORY_STORAGE_TYPE,
                "blocks": entry[0x13] | entry[0x14] << 8,
                "eof": entry[0x15] | entry[0x16] << 8 | entry[0x17] << 16,
            })
        block_number = block[2] | block[3] << 8

    free_blocks = None
    if 0 < bitmap_block < total_blocks <= TRACK_COUNT * BLOCKS_PER_TRACK:
        bitmap = image.prodos_block(bitmap_block)
        free_blocks = sum((bitmap[i // 8] >> (7 - i % 8)) & 1 for i in range(total_blocks))
    return {
        "type": "prodos",
        "volume_name": volume_name,
        "catalog": entries,
        "catalog_entry_count": len(entries),
        "catalog_scope": "volume directory only (subdirectories not walked)",
        "total_blocks": total_blocks,
        "free_blocks": free_blocks,
    }


@dataclass(frozen=True)
class OrderDetection:
    image: SectorImage
    filesystem: dict[str, Any] | None
    basis: str
    evidence: dict[str, Any]


def order_score(filesystem: dict[str, Any] | None) -> int:
    """How strongly a parsed filesystem supports its sector order."""
    if filesystem is None:
        return 0
    return 1 + filesystem.get("_valid_ts_lists", filesystem["catalog_entry_count"])


def detect_sector_order(data: bytes, extension: str) -> OrderDetection:
    """Try both sector orders. DOS 3.3 track 17 sectors 0 and 15 sit at the same file
    offset in both orders, so a catalog alone can match twice; valid track/sector
    lists break the tie, then the file extension."""
    preferred = "prodos" if extension == ".po" else "dos"
    other = "dos" if preferred == "prodos" else "prodos"
    evidence: dict[str, Any] = {}
    found: dict[str, dict[str, Any] | None] = {}
    for order in (preferred, other):
        image = SectorImage(data, order)
        dos33 = parse_dos33(image)
        prodos = parse_prodos(image)
        found[order] = dos33 or prodos
        evidence[f"{order}_order"] = {
            "dos33_catalog": dos33 is not None,
            "prodos_directory": prodos is not None,
            "valid_ts_lists": dos33["_valid_ts_lists"] if dos33 else None,
            "score": order_score(found[order]),
        }
    preferred_score, other_score = order_score(found[preferred]), order_score(found[other])
    if preferred_score == 0 and other_score == 0:
        chosen, basis = preferred, "file extension (no filesystem found in either order)"
    elif preferred_score == other_score:
        chosen, basis = preferred, "file extension (both orders equally plausible)"
    elif preferred_score > other_score:
        chosen, basis = preferred, "filesystem structure"
    else:
        chosen, basis = other, "filesystem structure (overrides the file extension)"
    return OrderDetection(SectorImage(data, chosen), found[chosen], basis, evidence)


# ── Analysis steps ──────────────────────────────────────────────────────────

def classify_input(path: Path, size: int, head: bytes) -> dict[str, Any]:
    extension = path.suffix.lower()
    result: dict[str, Any] = {"status": "unsupported", "kind": "unknown", "extension": extension, "notes": []}
    if head[:4] in (b"WOZ1", b"WOZ2"):
        result.update(kind="woz", reason="WOZ flux image; only plain 140K sector images (.dsk/.do/.po) are supported")
    elif head[:4] == b"2IMG":
        result.update(kind="2mg", reason="2IMG container; extract the sector image first")
    elif size == NIB_IMAGE_SIZE:
        result.update(kind="nib", reason="nibble image (raw disk bytes, 35 x 6656); convert to a .dsk sector image first")
    elif size != SECTOR_IMAGE_SIZE:
        result.update(reason=f"size {size:,} bytes is neither a 140K sector image ({SECTOR_IMAGE_SIZE:,}) nor a .nib ({NIB_IMAGE_SIZE:,})")
    else:
        result.update(status="supported", kind="sector-image", reason=None)
    if result["kind"] == "nib" and extension != ".nib":
        result["notes"].append(f"extension is {extension or '(none)'} but the size matches a .nib image")
    if result["kind"] == "sector-image" and extension == ".nib":
        result["notes"].append("extension is .nib but the size matches a 140K sector image")
    return result


def map_track_usage(image: SectorImage, filesystem: dict[str, Any] | None) -> dict[str, Any]:
    empty: list[list[int]] = []
    used_per_track: list[int] = []
    free_but_nonempty: list[list[int]] = []
    free_map = filesystem.get("_free_map") if filesystem else None
    for track in range(TRACK_COUNT):
        used = 0
        for sector in range(SECTORS_PER_TRACK):
            has_data = any(image.dos_sector(track, sector))
            if has_data:
                used += 1
            else:
                empty.append([track, sector])
            if free_map is not None and has_data and (free_map[track] >> sector) & 1:
                free_but_nonempty.append([track, sector])
        used_per_track.append(used)
    return {
        "sector_numbering": "DOS logical",
        "used_sectors_per_track": used_per_track,
        "tracks_with_data": [track for track, used in enumerate(used_per_track) if used],
        "empty_tracks": [track for track, used in enumerate(used_per_track) if not used],
        "empty_sectors": empty,
        "empty_sector_count": len(empty),
        "used_sector_count": TRACK_COUNT * SECTORS_PER_TRACK - len(empty),
        "marked_free_but_nonempty": free_but_nonempty if free_map is not None else None,
    }


def identify_loader(boot_sector: bytes, filesystem: dict[str, Any] | None, tracks: dict[str, Any]) -> dict[str, Any]:
    signature = next((known for known in KNOWN_LOADERS if boot_sector.startswith(known.boot_prefix)), None)
    evidence: list[str] = []
    custom_signs: list[str] = []
    if signature:
        evidence.append(f"boot sector starts {signature.boot_prefix.hex(' ').upper()} ({signature.name} pattern)")
    else:
        custom_signs.append(f"boot sector starts {boot_sector[:5].hex(' ').upper()}, which matches no known standard loader")
    if signature and signature.custom:
        custom_signs.append(f"boot sector matches the {signature.name} pattern")

    catalog_names = [entry["name"] for entry in (filesystem or {}).get("catalog", [])]
    if signature and signature.loader_id == "mecc":
        hints = [name for name in catalog_names if any(hint.match(name) for hint in MECC_CATALOG_HINTS)]
        evidence.extend(f"MECC catalog marker: {name}" for name in hints)

    if filesystem is None:
        custom_signs.append("no DOS 3.3 catalog or ProDOS directory in either sector order")
    elif filesystem["type"] == "dos33":
        used = tracks["used_sector_count"]
        listed = filesystem["catalog_sector_total"]
        coverage = listed / used if used else 0.0
        if coverage < CATALOG_COVERAGE_THRESHOLD:
            custom_signs.append(f"catalog files account for {listed} of {used} used sectors ({coverage:.1%}); the rest is read directly by a loader")
        if filesystem["free_sectors"] == 0:
            custom_signs.append("VTOC bitmap marks every sector in use (full-disk bitmap)")

    is_custom = bool(custom_signs)
    if signature and signature.custom:
        loader_id, name, confidence = signature.loader_id, signature.name, signature.confidence
        label = f"custom {name}"
    elif signature and is_custom:
        loader_id, name, confidence = signature.loader_id, signature.name, "heuristic"
        label = f"{name} boot with custom data loading"
    elif signature:
        loader_id, name, confidence = signature.loader_id, signature.name, signature.confidence
        label = f"standard {name}"
    else:
        loader_id, name, confidence = "unknown-custom", "unidentified loader", "heuristic"
        label = "custom loader (unidentified)"
    return {
        "id": loader_id,
        "name": name,
        "label": label,
        "custom": is_custom,
        "confidence": confidence,
        "evidence": evidence,
        "custom_loader_signs": custom_signs,
    }


def describe_external_target(address: int) -> str:
    if address >= MONITOR_ROM_START:
        routine = MONITOR_ROUTINES.get(address)
        return f"Monitor ROM {routine}" if routine else "Monitor ROM (or language-card RAM)"
    if address >= UPPER_ROM_START:
        return "Applesoft ROM area (or language-card RAM)"
    if address > SOFT_SWITCH_END and address <= SLOT_ROM_END:
        return "slot/peripheral ROM"
    if address >= IO_START:
        return "I/O soft switch"
    if BOOT_LOAD_ADDRESS <= address <= LOADER_AREA_END:
        return "loader code loaded after the boot sector"
    return "RAM"


def describe_soft_switch(instruction: Instruction) -> str:
    address = instruction.operand or 0
    indexed = instruction.mode in ("abx", "aby")
    if indexed and 0xC080 <= address <= 0xC08F:
        return f"{DISK_II_REGISTERS.get(address & 0x0F, 'Disk II register')} (slot-relative)"
    return SOFT_SWITCHES.get(address, "soft switch")


def load_boot_code(image: SectorImage) -> tuple[bytes, int]:
    """The Disk II boot ROM loads physical sectors 0..N-1 of track 0 to $0800, N = byte $0800."""
    first_sector = image.physical_sector(0, 0)
    sector_count = min(max(first_sector[0], 1), SECTORS_PER_TRACK)
    code = b"".join(image.physical_sector(0, physical) for physical in range(sector_count))
    return code, sector_count


def analyze_boot(image: SectorImage, loader: dict[str, Any]) -> dict[str, Any]:
    code, sector_count = load_boot_code(image)
    trace = trace_code(code, BOOT_LOAD_ADDRESS, BOOT_ENTRY_ADDRESS)
    instructions = [trace.instructions[address] for address in sorted(trace.instructions)]

    entry_candidates = sorted({
        target for _, target in trace.external_jumps
        if LOWEST_PROGRAM_ADDRESS <= target < IO_START and not BOOT_LOAD_ADDRESS <= target <= LOADER_AREA_END
    })
    if not loader["custom"]:
        entry_status, entry_point = "not-applicable", None
        entry_note = "standard OS boot: the program starts from a catalog file (e.g. HELLO), not a raw address"
    elif len(entry_candidates) == 1:
        entry_status, entry_point = "found", entry_candidates[0]
        entry_note = "only direct jump out of the loader into program RAM"
    elif entry_candidates:
        entry_status, entry_point = "ambiguous", None
        entry_note = "several direct jumps leave the loader; see entry_candidates"
    else:
        entry_status, entry_point = "not-found", None
        entry_note = "no direct jump into program RAM; the loader may jump indirectly or from a later stage"

    soft_switches = [
        {"at": f"${instruction.address:04X}", "instruction": instruction.text(), "meaning": describe_soft_switch(instruction)}
        for instruction in instructions
        if instruction.mode in ("abs", "abx", "aby") and IO_START <= (instruction.operand or 0) <= SOFT_SWITCH_END
    ]
    return {
        "load_address": f"${BOOT_LOAD_ADDRESS:04X}",
        "sectors_loaded_by_boot_rom": sector_count,
        "trace_start": f"${BOOT_ENTRY_ADDRESS:04X}",
        "entry_point": f"${entry_point:04X}" if entry_point is not None else None,
        "entry_point_status": entry_status,
        "entry_point_note": entry_note,
        "entry_candidates": [f"${target:04X}" for target in entry_candidates],
        "external_jumps": [
            {"at": f"${at:04X}", "target": f"${target:04X}", "kind": describe_external_target(target)}
            for at, target in trace.external_jumps
        ],
        "external_calls": [
            {"at": f"${at:04X}", "target": f"${target:04X}", "kind": describe_external_target(target)}
            for at, target in trace.external_calls
        ],
        "indirect_jumps": [{"at": f"${at:04X}", "pointer": f"${pointer:04X}"} for at, pointer in trace.indirect_jumps],
        "soft_switches": soft_switches,
        "trace_stops": [{"at": f"${at:04X}", "reason": reason} for at, reason in trace.stopped_at],
        "disassembly": [
            {"address": f"${instruction.address:04X}", "bytes": instruction.raw.hex(" ").upper(), "text": instruction.text()}
            for instruction in instructions
        ],
    }


def group_read_markers(sector_bytes: bytes) -> list[list[tuple[int, int]]]:
    groups: list[list[tuple[int, int]]] = []
    for match in READ_MARKER_PATTERN.finditer(sector_bytes):
        marker = (match.start(1), match.group(1)[0])
        if groups and marker[0] - groups[-1][-1][0] <= MARKER_GROUP_GAP:
            groups[-1].append(marker)
        else:
            groups.append([marker])
    return groups


def classify_marker_sequence(values: tuple[int, ...]) -> str:
    if len(values) >= 3 and values[:3] in (STANDARD_ADDRESS_PROLOGUE, STANDARD_DATA_PROLOGUE):
        return "standard"
    if len(values) >= 2 and values[:2] == STANDARD_EPILOGUE:
        return "standard"
    if len(values) < 2:
        return "too-short-to-judge"
    return "non-standard"


def scan_protection(image: SectorImage, loader: dict[str, Any]) -> dict[str, Any]:
    sequences: list[dict[str, Any]] = []
    for sector in range(SECTORS_PER_TRACK):
        sector_bytes = image.dos_sector(0, sector)
        for group in group_read_markers(sector_bytes):
            values = tuple(value for _, value in group)
            sequences.append({
                "kind": "read", "track": 0, "sector": sector, "offset": f"${group[0][0]:02X}",
                "values": [f"${value:02X}" for value in values], "verdict": classify_marker_sequence(values),
            })
        for match in WRITE_PROLOGUE_PATTERN.finditer(sector_bytes):
            values = tuple(match.group(index)[0] for index in (1, 2, 3))
            sequences.append({
                "kind": "write", "track": 0, "sector": sector, "offset": f"${match.start(1):02X}",
                "values": [f"${value:02X}" for value in values], "verdict": classify_marker_sequence(values),
            })

    crack_matches = []
    for crack in KNOWN_CRACKS:
        matched = sum(image.dos_sector(track, sector)[offset] == value for track, sector, offset, value in crack.patches)
        crack_matches.append({"name": crack.name, "source": crack.source, "matched": matched, "total": len(crack.patches)})
    full_match = next((match for match in crack_matches if match["matched"] == match["total"]), None)

    nonstandard = [sequence for sequence in sequences if sequence["verdict"] == "non-standard"]
    judged = [sequence for sequence in sequences if sequence["verdict"] != "too-short-to-judge"]
    if full_match:
        status = "already-cracked"
        explanation = f"all {full_match['total']} patches of a known crack are present ({full_match['name']})"
    elif nonstandard:
        status = "protected"
        explanation = "the disk's own read/write code expects non-standard markers; a plain sector image probably will not boot"
    elif not judged:
        status = "unknown"
        explanation = "no disk read/write marker code found on track 0; protection status cannot be judged"
    elif loader["custom"]:
        status = "standard-format"
        explanation = "custom loader uses standard markers and matches no known crack: unprotected, or cracked by an unknown method"
    else:
        status = "unprotected"
        explanation = "standard loader with standard markers; no protection signs"
    return {
        "status": status,
        "explanation": explanation,
        "marker_sequences": sequences,
        "known_crack_checks": crack_matches,
        "scope": "track 0 only; protection checks in later tracks or at run time are not detected",
    }


# ── Report assembly ─────────────────────────────────────────────────────────

def disk_slug(path: Path) -> str:
    return re.sub(r"[^a-z0-9]+", "-", path.stem.lower()).strip("-") or "disk"


def build_headline(analysis: dict[str, Any]) -> str:
    format_info = analysis["format"]
    if format_info["status"] != "supported":
        return f"Unsupported input ({format_info['kind']}): {format_info['reason']}"
    entry = analysis["boot"]["entry_point"] or analysis["boot"]["entry_point_status"]
    entries = analysis["filesystem"]["catalog_entry_count"] if analysis["filesystem"] else 0
    return f"{analysis['boot']['loader']['label']}, entry {entry}, {analysis['protection']['status']}, {entries} catalog entries"


def analyze(path: Path) -> dict[str, Any]:
    size = path.stat().st_size
    with path.open("rb") as handle:
        data = handle.read(MAX_INPUT_SIZE + 1)
    format_info = classify_input(path, size, data[:4])
    analysis: dict[str, Any] = {
        "schema_version": ANALYSIS_SCHEMA_VERSION,
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "input": {
            "file_name": path.name,
            "size_bytes": size,
            "sha256": hashlib.sha256(data).hexdigest() if size <= MAX_INPUT_SIZE else None,
        },
        "format": format_info,
        "filesystem": None,
        "tracks": None,
        "boot": None,
        "protection": None,
    }
    if format_info["status"] == "supported":
        detection = detect_sector_order(data, format_info["extension"])
        image, filesystem = detection.image, detection.filesystem
        format_info["sector_order"] = image.order
        format_info["sector_order_basis"] = detection.basis
        format_info["sector_order_evidence"] = detection.evidence
        format_info["apple2tc_readable"] = image.order == "dos"
        tracks = map_track_usage(image, filesystem)
        loader = identify_loader(image.physical_sector(0, 0), filesystem, tracks)
        boot = analyze_boot(image, loader)
        boot["loader"] = loader
        analysis.update(
            filesystem={key: value for key, value in filesystem.items() if not key.startswith("_")} if filesystem else None,
            tracks=tracks,
            boot=boot,
            protection=scan_protection(image, loader),
        )
    analysis["summary"] = {
        "supported": format_info["status"] == "supported",
        "loader_id": analysis["boot"]["loader"]["id"] if analysis["boot"] else None,
        "custom_loader": analysis["boot"]["loader"]["custom"] if analysis["boot"] else None,
        "entry_point": analysis["boot"]["entry_point"] if analysis["boot"] else None,
        "protection_status": analysis["protection"]["status"] if analysis["protection"] else None,
        "catalog_entry_count": analysis["filesystem"]["catalog_entry_count"] if analysis["filesystem"] else 0,
        "headline": build_headline(analysis),
    }
    return analysis


def render_markdown(analysis: dict[str, Any]) -> str:
    lines = [f"# Disk analysis: {analysis['input']['file_name']}", ""]
    lines += [f"**Summary:** {analysis['summary']['headline']}", ""]
    lines += [
        f"- Size: {analysis['input']['size_bytes']:,} bytes",
        f"- SHA-256: `{analysis['input']['sha256']}`",
        f"- Generated: {analysis['generated']}",
        "",
    ]
    format_info = analysis["format"]
    if format_info["status"] != "supported":
        lines += ["## Unsupported input", "", f"{format_info['reason']}.", ""]
        lines += [f"- Note: {note}" for note in format_info["notes"]]
        lines += ["", "Nothing else was analyzed. No conversion tier is possible until the image is converted to a 140K `.dsk`.", ""]
        return "\n".join(lines)

    lines += ["## Format", ""]
    lines.append(f"- 140K sector image in **{format_info['sector_order'].upper()} order** (decided by {format_info['sector_order_basis']}).")
    lines.append(f"- apple2tc can read it directly: {'yes' if format_info['apple2tc_readable'] else 'no (needs DOS order)'}.")
    lines += [f"- Note: {note}" for note in format_info["notes"]]

    filesystem = analysis["filesystem"]
    lines += ["", "## Catalog", ""]
    if filesystem is None:
        lines.append("No DOS 3.3 catalog or ProDOS directory found.")
    else:
        if filesystem["type"] == "dos33":
            lines.append(f"DOS 3.3, volume {filesystem['volume']}, {filesystem['free_sectors']} of {filesystem['total_sectors']} sectors free.")
            lines += ["", "| Name | Type | Sectors | Locked |", "|---|---|---|---|"]
            lines += [f"| `{entry['name']}` | {entry['type']} ({entry['type_description']}) | {entry['sectors']} | {'yes' if entry['locked'] else 'no'} |" for entry in filesystem["catalog"]]
        else:
            lines.append(f"ProDOS volume `/{filesystem['volume_name']}`, {filesystem['free_blocks']} of {filesystem['total_blocks']} blocks free ({filesystem['catalog_scope']}).")
            lines += ["", "| Name | Type | Blocks |", "|---|---|---|"]
            lines += [f"| `{entry['name']}` | {entry['type']} | {entry['blocks']} |" for entry in filesystem["catalog"]]

    boot, loader = analysis["boot"], analysis["boot"]["loader"]
    lines += ["", "## Loader", ""]
    lines.append(f"- Loader: **{loader['name']}** ({'custom' if loader['custom'] else 'standard'}; confidence: {loader['confidence']}).")
    lines += [f"- Evidence: {item}" for item in loader["evidence"]]
    lines += [f"- Custom-loader sign: {item}" for item in loader["custom_loader_signs"]]
    lines.append(f"- Entry point: **{boot['entry_point'] or boot['entry_point_status']}** ({boot['entry_point_note']}).")
    if boot["external_calls"]:
        lines.append("- Calls out of the boot sector: " + ", ".join(f"{call['target']} ({call['kind']})" for call in boot["external_calls"]) + ".")
    if boot["soft_switches"]:
        lines.append("- Hardware switches touched: " + "; ".join(f"`{switch['instruction']}` = {switch['meaning']}" for switch in boot["soft_switches"]) + ".")

    tracks = analysis["tracks"]
    lines += ["", "## Track usage", ""]
    lines.append(f"- {tracks['used_sector_count']} sectors hold data, {tracks['empty_sector_count']} are all zeros.")
    lines.append(f"- Tracks with no data: {', '.join(map(str, tracks['empty_tracks'])) or 'none'}.")
    if tracks["marked_free_but_nonempty"]:
        lines.append(f"- {len(tracks['marked_free_but_nonempty'])} sectors are marked free but contain data.")

    protection = analysis["protection"]
    lines += ["", "## Copy protection", ""]
    lines.append(f"- Status: **{protection['status']}**: {protection['explanation']}.")
    for check in protection["known_crack_checks"]:
        lines.append(f"- Known crack check: {check['name']}: {check['matched']}/{check['total']} patches present.")
    for sequence in protection["marker_sequences"]:
        lines.append(f"- T0 S{sequence['sector']:X} {sequence['offset']} {sequence['kind']} markers {' '.join(sequence['values'])}: {sequence['verdict']}.")
    lines.append(f"- Scope: {protection['scope']}.")

    lines += ["", "## Boot sector disassembly (reachable code only)", "", "```"]
    lines += [f"{row['address']}  {row['bytes']:<9}  {row['text']}" for row in boot["disassembly"]]
    lines += ["```", ""]
    return "\n".join(lines)


def write_atomically(target: Path, content: str) -> None:
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temporary, target)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def write_outputs(analysis: dict[str, Any], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    write_atomically(out_dir / "analysis.json", json.dumps(analysis, indent=2) + "\n")
    write_atomically(out_dir / "analysis.md", render_markdown(analysis))


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze an Apple II disk image (read-only). Writes analysis.json and analysis.md.",
    )
    parser.add_argument("image", type=Path, help="disk image (.dsk, .do, .po; .nib/.woz are reported unsupported)")
    parser.add_argument("--out", type=Path, help="output folder (default: work/<disk-slug>/ in the repo)")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    image_path: Path = arguments.image
    if not image_path.is_file():
        print(f"ERROR: not a file: {image_path}", file=sys.stderr)
        return 2
    repo_root = Path(__file__).resolve().parent.parent
    out_dir: Path = arguments.out or repo_root / "work" / disk_slug(image_path)
    try:
        analysis = analyze(image_path)
        write_outputs(analysis, out_dir)
    except OSError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(analysis["summary"]["headline"])
    print(f"Wrote {out_dir / 'analysis.json'} and analysis.md")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
