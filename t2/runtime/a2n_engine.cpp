/*
 * Derived from apple2tc lib/engine6502/engine6502.cpp (with this project's
 * vendor/patches applied). Copyright (c) Tzvetan Mikov. MIT license (see
 * vendor/apple2tc/LICENSE).
 */

/// \file
/// The T2-hybrid engine: compiled C for the game's code, the 6502 interpreter
/// for anything the compiled code does not cover.
///
/// The machine is the interpreter's (Emu6502 with a Language Card, the host's
/// Disk II and video). Before each instruction the engine looks for a compiled
/// block at pc (t2_blocks, from tools/lib/t2_link.py) whose bytes match memory.
/// If one does, and the frame has room for it, the block runs as C on the same
/// registers and RAM; otherwise one instruction is interpreted. "Room" is
/// exactly the interpreter's own rule -- it starts an instruction while the
/// frame's cycles are not used up -- so frames end on the same instruction and
/// the two engines produce identical frames.
///
/// The game starts from a snapshot taken at its title screen with all ROM
/// bytes removed (tools/lib/t2_image.py). No ROM is loaded or needed: the few
/// Monitor routines the game calls run as C (a2n_monitor.cpp), and the 12K
/// ROM area is a blank placeholder that only switches the Language Card on.

#include "a2n_block.h"
#include "a2n_monitor.h"

#include "apple2tc/a2engine.h"
#include "apple2tc/a2host.h"
#include "apple2tc/a2host_api.h"
#include "apple2tc/a2io.h"
#include "apple2tc/d6502.h"
#include "apple2tc/emu6502.h"
#include "apple2tc/probe.h"
#include "apple2tc/support.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

/// An Emu6502 whose IO goes to the host, with a 16K Language Card in slot 0.
/// Unchanged from engine6502.cpp's HostedEmu apart from the public IO entry
/// points the compiled blocks call through.
class HostedEmu : public Emu6502 {
public:
  HostedEmu() : Emu6502(0xC000, 0xCFFF) {}

  void powerOnLanguageCard(size_t romSize) {
    lcEnabled_ = romSize >= kLcSize;
    readRam_ = false;
    writeEnabled_ = false;
    bank2_ = true;
    prewrite_ = false;
    if (!lcEnabled_)
      return;
    memcpy(rom_, getMainRAM() + kLcBase, kLcSize);
    memset(bank1_, 0xFF, sizeof(bank1_));
    memset(bank2Ram_, 0xFF, sizeof(bank2Ram_));
    memset(high_, 0xFF, sizeof(high_));
  }

  bool languageCardEnabled() const {
    return lcEnabled_;
  }

  std::vector<uint8_t> saveLanguageCard() const {
    std::vector<uint8_t> out(kLcStateBytes, 0);
    memcpy(out.data(), kLcMagic, sizeof(kLcMagic));
    out[4] = kLcStateVersion;
    out[5] = switchFlags();
    uint8_t *bank1 = out.data() + kLcHeaderBytes;
    uint8_t *bank2 = bank1 + kLcBankSize;
    uint8_t *high = bank2 + kLcBankSize;
    memcpy(bank1, bank1_, kLcBankSize);
    memcpy(bank2, bank2Ram_, kLcBankSize);
    memcpy(high, high_, kLcHighSize);
    if (readRam_) {
      memcpy(bank2_ ? bank2 : bank1, getMainRAM() + kLcBase, kLcBankSize);
      memcpy(high, getMainRAM() + kLcHighBase, kLcHighSize);
    }
    return out;
  }

  bool restoreLanguageCard(const std::vector<uint8_t> &in) {
    if (!lcEnabled_ || in.size() != kLcStateBytes ||
        memcmp(in.data(), kLcMagic, sizeof(kLcMagic)) != 0 || in[4] != kLcStateVersion)
      return false;
    uint8_t flags = in[5];
    readRam_ = (flags & kFlagReadRam) != 0;
    bank2_ = (flags & kFlagBank2) != 0;
    writeEnabled_ = (flags & kFlagWriteEnabled) != 0;
    prewrite_ = (flags & kFlagPrewrite) != 0;
    const uint8_t *bank1 = in.data() + kLcHeaderBytes;
    memcpy(bank1_, bank1, kLcBankSize);
    memcpy(bank2Ram_, bank1 + kLcBankSize, kLcBankSize);
    memcpy(high_, bank1 + 2 * kLcBankSize, kLcHighSize);
    uint8_t *ram = getMainRAMWritable();
    if (readRam_) {
      memcpy(ram + kLcBase, selectedBank(), kLcBankSize);
      memcpy(ram + kLcHighBase, high_, kLcHighSize);
    } else {
      memcpy(ram + kLcBase, rom_, kLcSize);
    }
    return true;
  }

protected:
  uint8_t ioPeek(uint16_t addr) override {
    if (lcEnabled_ && (addr & 0xFFF0) == kLcSwitchBase) {
      languageCardSwitch(addr, true);
      return 0;
    }
    return io_peek(addr);
  }
  void ioPoke(uint16_t addr, uint8_t value) override {
    if (lcEnabled_ && (addr & 0xFFF0) == kLcSwitchBase) {
      languageCardSwitch(addr, false);
      return;
    }
    io_poke(addr, value);
  }
  void highWrite(uint16_t addr, uint8_t value) override {
    if (!lcEnabled_ || addr < kLcBase || !writeEnabled_)
      return;
    if (readRam_) {
      getMainRAMWritable()[addr] = value;
    } else if (addr < kLcHighBase) {
      selectedBank()[addr - kLcBase] = value;
    } else {
      high_[addr - kLcHighBase] = value;
    }
  }

private:
  static constexpr uint16_t kLcSwitchBase = 0xC080;
  static constexpr uint16_t kLcBase = 0xD000;
  static constexpr uint16_t kLcHighBase = 0xE000;
  static constexpr unsigned kLcBankSize = 0x1000;
  static constexpr unsigned kLcHighSize = 0x2000;
  static constexpr unsigned kLcSize = kLcBankSize + kLcHighSize;
  static constexpr char kLcMagic[4] = {'A', '2', 'L', 'C'};
  static constexpr uint8_t kLcStateVersion = 1;
  static constexpr unsigned kLcHeaderBytes = 8;
  static constexpr unsigned kLcStateBytes = kLcHeaderBytes + 2 * kLcBankSize + kLcHighSize;
  static constexpr uint8_t kFlagReadRam = 0x01;
  static constexpr uint8_t kFlagBank2 = 0x02;
  static constexpr uint8_t kFlagWriteEnabled = 0x04;
  static constexpr uint8_t kFlagPrewrite = 0x08;

  uint8_t switchFlags() const {
    return (readRam_ ? kFlagReadRam : 0) | (bank2_ ? kFlagBank2 : 0) |
        (writeEnabled_ ? kFlagWriteEnabled : 0) | (prewrite_ ? kFlagPrewrite : 0);
  }

  uint8_t *selectedBank() {
    return bank2_ ? bank2Ram_ : bank1_;
  }

  void languageCardSwitch(uint16_t addr, bool isRead) {
    if (addr & 0x01) {
      if (isRead) {
        if (prewrite_)
          writeEnabled_ = true;
        prewrite_ = true;
      } else {
        prewrite_ = false;
      }
    } else {
      writeEnabled_ = false;
      prewrite_ = false;
    }
    unsigned mode = addr & 0x03;
    mapReadSource(mode == 0 || mode == 3, (addr & 0x08) == 0);
  }

  void mapReadSource(bool readRam, bool bank2) {
    if (readRam == readRam_ && bank2 == bank2_)
      return;
    uint8_t *ram = getMainRAMWritable();
    if (readRam_) {
      memcpy(selectedBank(), ram + kLcBase, kLcBankSize);
      memcpy(high_, ram + kLcHighBase, kLcHighSize);
    }
    readRam_ = readRam;
    bank2_ = bank2;
    if (readRam_) {
      memcpy(ram + kLcBase, selectedBank(), kLcBankSize);
      memcpy(ram + kLcHighBase, high_, kLcHighSize);
    } else {
      memcpy(ram + kLcBase, rom_, kLcSize);
    }
  }

  bool lcEnabled_ = false;
  bool readRam_ = false;
  bool writeEnabled_ = false;
  bool bank2_ = true;
  bool prewrite_ = false;
  uint8_t rom_[kLcSize];
  uint8_t bank1_[kLcBankSize];
  uint8_t bank2Ram_[kLcBankSize];
  uint8_t high_[kLcHighSize];
};

/// The 12K the Language Card needs below it to switch on. Zero unless the
/// user passes their own ROM with --rom=: T2 ships none.
constexpr size_t kBlankRomSize = 0x3000;
constexpr unsigned kRomBase = 0xD000;
constexpr unsigned kLcStateHeader = 8;
constexpr unsigned kLcStateBank = 0x1000;
constexpr unsigned kRefillBlock = 0x100;
constexpr uint16_t kIoStart = 0xC000;
constexpr uint16_t kBootPromEntry = 0xC600;
constexpr uint16_t kResetVector = 0xFFFC;
constexpr uint8_t kJmpIndirect = 0x6C;
constexpr unsigned kMissReportLimit = 20;

HostedEmu s_emu;
a2_stop_reason_t s_stopReason = A2_STOP_CYCLES;
std::string s_restorePath;
std::string s_romPath;
std::vector<uint8_t> s_userRom;
std::string s_disk1Path;
std::string s_disk2Path;
std::string s_statsPath;
bool s_interpretOnly = false;
int s_cycleDebt = 0;
bool s_inBlock = false;

/// Per block, precomputed at start-up: instruction count and the cycles of
/// every instruction but the last (what must fit for the block to run whole).
std::vector<uint32_t> s_blockInstructions;
std::vector<uint32_t> s_cyclesBeforeLast;
/// First t2_blocks index at each address, or -1. Blocks are sorted by address.
std::vector<int32_t> s_firstBlock;

/// Why each instruction ran where it did.
struct Stats {
  uint64_t nativeBlocks = 0;
  uint64_t nativeInstructions = 0;
  uint64_t monitorInstructions = 0;
  uint64_t frameSplit = 0;
  uint64_t uncompiled = 0;
  uint64_t changedCode = 0;
  std::unordered_map<uint16_t, uint64_t> uncompiledAt;
  std::unordered_map<uint16_t, uint64_t> changedAt;
  std::unordered_map<uint16_t, uint64_t> monitorMissAt;
  uint64_t restarts = 0;
  unsigned firstRestartCycle = 0;
};
Stats s_stats;
/// Why the compiled block at [start, end) was interpreted instead. Later
/// instructions that step forward through that range share the reason: they
/// are the rest of that block, not code T2 lacks.
enum class MissReason { None, FrameSplit, ChangedCode };
struct BlockMiss {
  MissReason reason = MissReason::None;
  uint32_t start = 0;
  uint32_t end = 0;
  uint32_t lastPc = 0;
};
BlockMiss s_miss;
bool s_statsWritten = false;

std::vector<uint8_t> readFileOrDie(const std::string &path) {
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) {
    perror(path.c_str());
    exit(2);
  }
  auto data = readAll<std::vector<uint8_t>>(f);
  fclose(f);
  return data;
}

void mountDisk(const std::string &path, int drive) {
  auto data = readFileOrDie(path);
  if (!a2_disk2_mount(&a2host_io()->disk2, drive, data.data(), data.size())) {
    fprintf(stderr, "Failed to mount disk%d: %s (bad format or size)\n", drive + 1, path.c_str());
    exit(2);
  }
}

[[noreturn]] void restoreFail(const std::string &path, const char *why) {
  fprintf(stderr, "ERROR: cannot restore %s: %s\n", path.c_str(), why);
  exit(2);
}

void saveDisk2State(const std::string &path) {
  const a2_disk2_t &d = a2host_io()->disk2;
  FILE *f = fopen(path.c_str(), "wt");
  if (!f) {
    perror(path.c_str());
    exit(2);
  }
  fprintf(
      f,
      "data_register %u\nq6 %d\nq7 %d\nmotor_on %d\nmotor_off_cycle %llu\n"
      "last_nibble_cycle %u\nselected_drive %d\nphases %u\nphase_position %d\n",
      d.data_register,
      (int)d.q6,
      (int)d.q7,
      (int)d.motor_on,
      (unsigned long long)d.motor_off_cycle,
      d.last_nibble_cycle,
      d.selected_drive,
      d.phases,
      d.phase_position);
  for (int i = 0; i != 2; ++i) {
    const a2_disk2_drive_t &drv = d.drive[i];
    fprintf(
        f,
        "drive%d_mounted %d\ndrive%d_position %u\ndrive%d_skip %d\ndrive%d_current_track %d\n",
        i, (int)drv.mounted, i, drv.position, i, (int)drv.skip, i, drv.current_track);
  }
  fclose(f);
}

void restoreDisk2State(const std::string &path) {
  std::ifstream in(path);
  if (!in)
    restoreFail(path, "cannot open");
  std::map<std::string, unsigned long long> v;
  std::string name;
  unsigned long long value;
  while (in >> name >> value)
    v[name] = value;
  const char *const kNeeded[] = {
      "data_register", "q6", "q7", "motor_on", "motor_off_cycle", "last_nibble_cycle",
      "selected_drive", "phases", "phase_position", "drive0_mounted", "drive0_position",
      "drive0_skip", "drive0_current_track", "drive1_mounted", "drive1_position",
      "drive1_skip", "drive1_current_track"};
  for (const char *needed : kNeeded)
    if (!v.count(needed))
      restoreFail(path, (std::string("missing ") + needed).c_str());

  a2_disk2_t &d = a2host_io()->disk2;
  for (int i = 0; i != 2; ++i) {
    std::string prefix = "drive" + std::to_string(i) + "_";
    a2_disk2_drive_t &drv = d.drive[i];
    if (v[prefix + "mounted"] != (drv.mounted ? 1u : 0u))
      restoreFail(path, ("drive " + std::to_string(i + 1) +
                         (drv.mounted ? " is mounted now but was empty when saved"
                                      : " was mounted when saved; give the same --disk")).c_str());
    drv.position = (uint32_t)v[prefix + "position"];
    drv.skip = v[prefix + "skip"] != 0;
    drv.current_track = (int)v[prefix + "current_track"];
  }
  d.data_register = (uint8_t)v["data_register"];
  d.q6 = v["q6"] != 0;
  d.q7 = v["q7"] != 0;
  d.motor_on = v["motor_on"] != 0;
  d.motor_off_cycle = v["motor_off_cycle"];
  d.last_nibble_cycle = (unsigned)v["last_nibble_cycle"];
  d.selected_drive = (int)v["selected_drive"];
  d.phases = (uint8_t)v["phases"];
  d.phase_position = (int)v["phase_position"];
}

/// Puts back, from the user's own ROM, the blocks t2_image.py blanked that
/// were identical to it (listed in PATH.blanked), so the machine matches the
/// original capture and code with no C routine (e.g. Monitor HOME on a
/// disk-error path) runs the same bytes a2emu would.
void refillFromUserRom(const std::string &path, std::vector<uint8_t> &ram, std::vector<uint8_t> &lc) {
  std::ifstream in(path + ".blanked");
  if (!in)
    restoreFail(path + ".blanked", "cannot open; rebuild with tools/50_recompile.sh");
  if (lc.size() != kLcStateHeader + 4 * kLcStateBank)
    restoreFail(path + ".lc", "not a Language Card state file for this machine");
  std::string area, hex;
  while (in >> area >> hex) {
    unsigned addr = (unsigned)strtoul(hex.c_str(), nullptr, 16);
    uint8_t *dest = nullptr;
    if (addr % kRefillBlock == 0 && addr >= kRomBase && addr <= 0xFF00) {
      unsigned bankOffset = addr - kRomBase;
      if (area == "ram")
        dest = ram.data() + addr;
      else if (area == "lc_bank1" && addr < 0xE000)
        dest = lc.data() + kLcStateHeader + bankOffset;
      else if (area == "lc_bank2" && addr < 0xE000)
        dest = lc.data() + kLcStateHeader + kLcStateBank + bankOffset;
      else if (area == "lc_high" && addr >= 0xE000)
        dest = lc.data() + kLcStateHeader + kLcStateBank + bankOffset;
    }
    if (!dest)
      restoreFail(path + ".blanked", ("bad line: " + area + " " + hex).c_str());
    memcpy(dest, s_userRom.data() + (addr - kRomBase), kRefillBlock);
  }
}

void restoreSnapshot(const std::string &path) {
  auto ram = readFileOrDie(path);
  if (ram.size() != 0x10000)
    restoreFail(path, "RAM image is not 65536 bytes");
  auto lc = readFileOrDie(path + ".lc");
  if (!s_userRom.empty())
    refillFromUserRom(path, ram, lc);

  std::ifstream regsFile(path + ".regs");
  if (!regsFile)
    restoreFail(path + ".regs", "cannot open");
  const char *const kNeeded[] = {
      "pc", "a", "x", "y", "sp", "status", "cycles", "vid_control", "kbd_last_key", "kbd_queued"};
  unsigned long values[std::size(kNeeded)];
  bool seen[std::size(kNeeded)] = {};
  std::string name, value;
  while (regsFile >> name >> value) {
    for (size_t i = 0; i != std::size(kNeeded); ++i) {
      if (name == kNeeded[i]) {
        bool decimal = name == "cycles" || name == "kbd_queued";
        values[i] = strtoul(value.c_str(), nullptr, decimal ? 10 : 16);
        seen[i] = true;
      }
    }
  }
  for (size_t i = 0; i != std::size(kNeeded); ++i)
    if (!seen[i])
      restoreFail(path + ".regs", (std::string("missing ") + kNeeded[i]).c_str());
  enum { PC, A, X, Y, SP, STATUS, CYCLES, VID_CONTROL, KBD_LAST_KEY, KBD_QUEUED };
  if (values[KBD_QUEUED] > 1)
    restoreFail(path, "more than one key was pending; type-ahead is not restorable");

  memcpy(s_emu.getMainRAMWritable(), ram.data(), ram.size());
  if (!s_emu.restoreLanguageCard(lc))
    restoreFail(path + ".lc", "not a Language Card state file for this machine");
  restoreDisk2State(path + ".disk");
  s_emu.setRegs(Emu6502::Regs{
      .pc = (uint16_t)values[PC],
      .a = (uint8_t)values[A],
      .x = (uint8_t)values[X],
      .y = (uint8_t)values[Y],
      .status = (uint8_t)values[STATUS],
      .sp = (uint8_t)values[SP]});
  s_emu.setCycles((unsigned)values[CYCLES]);

  a2_iostate_t *io = a2host_io();
  io->vid_control = (uint8_t)values[VID_CONTROL];
  io->clock = io->clock_last = (unsigned)values[CYCLES];
  io->keys_head = 0;
  io->keys_count = 0;
  io->latch = (uint8_t)values[KBD_LAST_KEY];
  io->strobe = values[KBD_QUEUED] != 0;
}

Emu6502::StopReason debugCB(void *, Emu6502 *, uint16_t pc) {
  if (g_debug & DebugASM)
    debug_asm(pc);
  if (g_probe_sites)
    probe_dispatch(pc);
  return Emu6502::StopReason::None;
}

/// Walk each block's compiled bytes once: count its instructions and the
/// cycles before its last one, and index blocks by address.
void indexBlocks() {
  for (unsigned op = 0; op != 256; ++op)
    t2_opcode_cycles[op] = decodeOpcode((uint8_t)op).cycles;
  s_firstBlock.assign(0x10000, -1);
  s_blockInstructions.resize(t2_block_count);
  s_cyclesBeforeLast.resize(t2_block_count);
  for (unsigned i = 0; i != t2_block_count; ++i) {
    const t2_block_t &b = t2_blocks[i];
    if (s_firstBlock[b.addr] < 0)
      s_firstBlock[b.addr] = (int32_t)i;
    const uint8_t *code = t2_block_bytes + b.bytes;
    unsigned offset = 0, count = 0, before = 0, last = 0;
    while (offset < b.length) {
      CPUOpcode op = decodeOpcode(code[offset]);
      before += last;
      last = op.cycles;
      offset += cpuInstSize(op.addrMode);
      ++count;
    }
    if (offset != b.length) {
      fprintf(stderr, "ERROR: T2 block $%04X does not decode to its length\n", b.addr);
      exit(2);
    }
    s_blockInstructions[i] = count;
    s_cyclesBeforeLast[i] = before;
  }
}

bool blockMatches(const t2_block_t &b) {
  const uint8_t *ram = s_emu.getMainRAM() + b.addr;
  const uint8_t *code = t2_block_bytes + b.bytes;
  const uint8_t *mask = t2_block_masks + b.bytes;
  for (unsigned i = 0; i != b.length; ++i)
    if ((ram[i] & mask[i]) != code[i])
      return false;
  return true;
}

/// The compiled block for pc whose bytes are in memory: its index, or -1.
/// \p anyAtPc reports whether pc has compiled blocks at all.
int32_t findBlock(uint16_t pc) {
  int32_t i = s_firstBlock[pc];
  for (; i >= 0 && (unsigned)i < t2_block_count && t2_blocks[i].addr == pc; ++i)
    if (blockMatches(t2_blocks[i]))
      return i;
  return -1;
}

void runBlock(int32_t index) {
  const t2_block_t &b = t2_blocks[index];
  if (g_debug & DebugASM)
    debug_asm(b.addr);
  if (g_probe_sites)
    probe_dispatch(b.addr);
  auto r = s_emu.getRegs();
  s_pc = r.pc;
  s_a = r.a;
  s_x = r.x;
  s_y = r.y;
  s_status = r.status;
  s_sp = r.sp;
  s_cycles = s_emu.getCycles();
  s_inBlock = true;
  t2_group_runs[b.group]();
  s_inBlock = false;
  s_emu.setRegs(Emu6502::Regs{
      .pc = s_pc, .a = s_a, .x = s_x, .y = s_y, .status = s_status, .sp = s_sp});
  s_emu.setCycles(s_cycles);
  ++s_stats.nativeBlocks;
  s_stats.nativeInstructions += s_blockInstructions[index];
}

uint8_t monitorIoRead(uint16_t addr) {
  return s_emu.peek(addr);
}

bool runMonitor(uint16_t pc) {
  if (!a2n_monitor_range(pc))
    return false;
  if (g_probe_sites)
    probe_dispatch(pc);
  MonitorCpu cpu{s_emu.getRegs(), s_emu.getCycles(), s_emu.getMainRAMWritable(), monitorIoRead};
  s_cycles = cpu.cycles;
  if (!a2n_monitor_step(cpu)) {
    if (++s_stats.monitorMissAt[pc] == 1)
      fprintf(stderr, "WARN: T2 has no Monitor routine at $%04X; interpreting blank memory\n", pc);
    return false;
  }
  s_emu.setRegs(cpu.regs);
  s_emu.setCycles(cpu.cycles);
  ++s_stats.monitorInstructions;
  return true;
}

void noteBlockMiss(int32_t waitingBlock, uint16_t pc) {
  if (waitingBlock >= 0) {
    const t2_block_t &b = t2_blocks[waitingBlock];
    s_miss = {MissReason::FrameSplit, b.addr, (uint32_t)b.addr + b.length, pc};
    return;
  }
  bool insideMissedBlock = s_miss.reason != MissReason::None && pc > s_miss.lastPc &&
                           pc >= s_miss.start && pc < s_miss.end;
  int32_t i = s_firstBlock[pc];
  if (i >= 0) {
    uint32_t end = insideMissedBlock ? s_miss.end : pc;
    for (; (unsigned)i < t2_block_count && t2_blocks[i].addr == pc; ++i)
      end = std::max(end, (uint32_t)pc + t2_blocks[i].length);
    s_miss = {MissReason::ChangedCode, insideMissedBlock ? s_miss.start : pc, end, pc};
    return;
  }
  if (insideMissedBlock)
    s_miss.lastPc = pc;
  else
    s_miss.reason = MissReason::None;
}

void interpretOne(int32_t waitingBlock, uint16_t pc) {
  noteBlockMiss(waitingBlock, pc);
  switch (s_miss.reason) {
  case MissReason::FrameSplit:
    ++s_stats.frameSplit;
    break;
  case MissReason::ChangedCode:
    ++s_stats.changedCode;
    ++s_stats.changedAt[pc];
    break;
  case MissReason::None:
    ++s_stats.uncompiled;
    ++s_stats.uncompiledAt[pc];
    break;
  }
  s_emu.runFor(1);
}

std::string topAddresses(const std::unordered_map<uint16_t, uint64_t> &counts,
                         size_t limit = kMissReportLimit) {
  std::vector<std::pair<uint16_t, uint64_t>> sorted(counts.begin(), counts.end());
  std::sort(sorted.begin(), sorted.end(), [](auto &a, auto &b) {
    return a.second != b.second ? a.second > b.second : a.first < b.first;
  });
  if (sorted.size() > limit)
    sorted.resize(limit);
  std::string out = "[";
  for (size_t i = 0; i != sorted.size(); ++i) {
    char buf[48];
    snprintf(buf, sizeof(buf), "%s[\"$%04X\", %llu]", i ? ", " : "", sorted[i].first,
             (unsigned long long)sorted[i].second);
    out += buf;
  }
  return out + "]";
}

void writeStats() {
  if (s_statsPath.empty() || s_statsWritten)
    return;
  s_statsWritten = true;
  FILE *f = fopen(s_statsPath.c_str(), "wt");
  if (!f) {
    perror(s_statsPath.c_str());
    return;
  }
  const Stats &s = s_stats;
  uint64_t interpreted = s.frameSplit + s.uncompiled + s.changedCode;
  uint64_t total = s.nativeInstructions + s.monitorInstructions + interpreted;
  fprintf(
      f,
      "{\n  \"native_blocks\": %llu,\n  \"native_instructions\": %llu,\n"
      "  \"monitor_instructions\": %llu,\n  \"interpreted_frame_split\": %llu,\n"
      "  \"interpreted_uncompiled\": %llu,\n  \"interpreted_changed_code\": %llu,\n"
      "  \"total_instructions\": %llu,\n  \"native_percent\": %.4f,\n"
      "  \"top_uncompiled\": %s,\n  \"top_changed_code\": %s,\n  \"monitor_misses\": %s,\n"
      "  \"restarts\": %llu,\n  \"first_restart_cycle\": %u\n}\n",
      (unsigned long long)s.nativeBlocks,
      (unsigned long long)s.nativeInstructions,
      (unsigned long long)s.monitorInstructions,
      (unsigned long long)s.frameSplit,
      (unsigned long long)s.uncompiled,
      (unsigned long long)s.changedCode,
      (unsigned long long)total,
      total ? 100.0 * (double)(s.nativeInstructions + s.monitorInstructions) / (double)total : 0.0,
      topAddresses(s.uncompiledAt).c_str(),
      topAddresses(s.changedAt).c_str(),
      topAddresses(s.monitorMissAt, s.monitorMissAt.size()).c_str(),
      (unsigned long long)s.restarts,
      s.firstRestartCycle);
  fclose(f);
}

} // namespace

/* --- a2n_block.h ---------------------------------------------------------- */

uint16_t s_pc = 0;
uint8_t s_a = 0;
uint8_t s_x = 0;
uint8_t s_y = 0;
uint8_t s_status = 0;
uint8_t s_sp = 0;
unsigned s_cycles = 0;
int s_remaining_cycles = 0;
uint8_t *s_ram = nullptr;
uint8_t t2_opcode_cycles[256];

uint8_t t2_io_read(uint16_t addr) {
  return s_emu.peek(addr);
}

void t2_high_write(uint16_t addr, uint8_t value) {
  s_emu.poke(addr, value);
}

void t2_unknown_block(uint16_t pc) {
  fprintf(stderr, "ERROR: T2 dispatched to $%04X, which its group does not compile\n", pc);
  abort();
}

/* --- a2engine.h ----------------------------------------------------------- */

uint8_t g_debug = 0;

void reset_regs(void) {
  s_emu.reset();
}

void set_regs(regs_t r) {
  s_emu.setRegs(Emu6502::Regs{
      .pc = r.pc, .a = r.a, .x = r.x, .y = r.y, .status = r.status, .sp = r.sp});
}

regs_t get_regs(void) {
  auto r = s_emu.getRegs();
  return regs_t{.pc = r.pc, .a = r.a, .x = r.x, .y = r.y, .status = r.status, .sp = r.sp};
}

unsigned get_cycles(void) {
  return s_inBlock ? s_cycles : s_emu.getCycles();
}

const uint8_t *get_ram(void) {
  return s_emu.getMainRAM();
}

void ram_poke(uint16_t addr, uint8_t value) {
  s_emu.ram_poke(addr, value);
}

uint8_t ram_peek(uint16_t addr) {
  return s_emu.ram_peek(addr);
}

uint16_t ram_peek16(uint16_t addr) {
  return (uint16_t)(s_emu.ram_peek(addr) + s_emu.ram_peek((uint16_t)(addr + 1)) * 256);
}

void init_emulated(void) {
  if (s_restorePath.empty()) {
    fprintf(stderr, "ERROR: T2 starts from its start image; pass --restore=PATH\n");
    exit(2);
  }
  std::vector<uint8_t> rom(kBlankRomSize, 0);
  if (!s_romPath.empty()) {
    s_userRom = readFileOrDie(s_romPath);
    if (s_userRom.size() != kBlankRomSize) {
      fprintf(stderr, "ERROR: %s is %zu bytes; an Apple II+ ROM is %zu\n", s_romPath.c_str(),
              s_userRom.size(), kBlankRomSize);
      exit(2);
    }
    rom = s_userRom;
  }
  s_emu.loadROM(rom.data(), (unsigned)rom.size());
  s_emu.powerOnLanguageCard(rom.size());
  if (!s_disk1Path.empty())
    mountDisk(s_disk1Path, 0);
  if (!s_disk2Path.empty())
    mountDisk(s_disk2Path, 1);
  restoreSnapshot(s_restorePath);

  s_ram = s_emu.getMainRAMWritable();
  indexBlocks();
  s_emu.setDebugStateCB(nullptr, debugCB);
  if ((g_debug & DebugASM) || probe_installed())
    s_emu.addDebugFlags(Emu6502::DebugASM);
  atexit(writeStats);
}

/// The game reboots the machine: JMP ($FFFC) into the Monitor's RESET, or a
/// jump to the slot 6 boot PROM. T2 has neither ROM (the start image has no
/// Monitor; the Disk II PROM is zeroed), so it does what rebooting this disk
/// ends in: the title screen, restored from the start image.
bool isReboot(uint16_t pc) {
  if (pc == kBootPromEntry)
    return true;
  return pc < kIoStart && s_ram[pc] == kJmpIndirect && s_ram[pc + 1] == (kResetVector & 0xFF) &&
         s_ram[pc + 2] == (kResetVector >> 8);
}

/// Keeps the clock running forward across the restore, so frame timing and
/// the Disk II's cycle stamps stay consistent.
void restartFromStartImage(uint16_t pc) {
  unsigned now = s_emu.getCycles();
  restoreSnapshot(s_restorePath);
  unsigned elapsed = now - s_emu.getCycles();
  a2_disk2_t &d = a2host_io()->disk2;
  d.motor_off_cycle += elapsed;
  d.last_nibble_cycle += elapsed;
  s_emu.setCycles(now);
  if (s_stats.restarts++ == 0) {
    s_stats.firstRestartCycle = now;
    fprintf(stderr, "T2: the game rebooted at $%04X; restarting at the title screen\n", pc);
  }
}

void run_emulated(unsigned run_cycles) {
  s_stopReason = A2_STOP_CYCLES;
  s_cycleDebt += (int)run_cycles;
  if (s_cycleDebt <= 0)
    return;
  const unsigned budget = (unsigned)s_cycleDebt;
  const unsigned start = s_emu.getCycles();
  for (unsigned used = 0; used < budget; used = s_emu.getCycles() - start) {
    uint16_t pc = s_emu.getRegs().pc;
    if (isReboot(pc)) {
      restartFromStartImage(pc);
      continue;
    }
    if (runMonitor(pc))
      continue;
    int32_t block = s_interpretOnly ? -1 : findBlock(pc);
    if (block >= 0 && used + s_cyclesBeforeLast[block] < budget) {
      runBlock(block);
      s_miss.reason = MissReason::None;
      continue;
    }
    interpretOne(block, pc);
  }
  s_cycleDebt -= (int)(s_emu.getCycles() - start);
}

void shutdown_emulated(void) {
  writeStats();
  s_emu.unloadROM();
  s_cycleDebt = 0;
}

a2_stop_reason_t engine_stop_reason(void) {
  return s_stopReason;
}

bool engine_parse_arg(const char *arg) {
  auto prefix = [arg](const char *p, std::string *out) {
    size_t n = strlen(p);
    if (strncmp(arg, p, n) != 0)
      return false;
    *out = arg + n;
    return true;
  };
  if (prefix("--restore=", &s_restorePath) || prefix("--disk1=", &s_disk1Path) ||
      prefix("--disk2=", &s_disk2Path) || prefix("--t2-stats=", &s_statsPath) ||
      prefix("--rom=", &s_romPath))
    return true;
  if (strcmp(arg, "--t2-interpret") == 0) {
    s_interpretOnly = true;
    return true;
  }
  return false;
}

void engine_print_help(void) {
  printf("\n T2-hybrid engine (compiled C, interpreter fallback; no ROM):\n");
  printf(" --restore=p      Start image (p, p.regs, p.lc, p.disk), required\n");
  printf(" --disk1=path     Mount a disk image in drive 1 (the start image's disk)\n");
  printf(" --disk2=path     Mount a disk image in drive 2\n");
  printf(" --rom=path       Optional: your own 12K Apple II+ ROM. Puts back the ROM bytes\n"
         "                  the start image left out, for code T2 has no C routine for\n");
  printf(" --t2-stats=path  Write native/interpreted instruction counts as JSON\n");
  printf(" --t2-interpret   Interpret everything (diagnostics: same machine, no C)\n");
}

/// Snapshots also save the Disk II state and the Language Card, as in a2emu.
extern "C" void engine_snapshot_extra(const char *ram_path) {
  saveDisk2State(std::string(ram_path) + ".disk");
  if (!s_emu.languageCardEnabled())
    return;
  std::string path = std::string(ram_path) + ".lc";
  auto data = s_emu.saveLanguageCard();
  FILE *f = fopen(path.c_str(), "wb");
  if (!f || fwrite(data.data(), 1, data.size(), f) != data.size()) {
    perror(path.c_str());
    exit(2);
  }
  fclose(f);
}
