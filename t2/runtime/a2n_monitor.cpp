/// \file
/// C equivalents of the Monitor entry points Number Munchers uses after its
/// title screen, from their documented behaviour (Apple II Reference Manual,
/// Monitor ROM listing):
///
///   PRBL2   $F94A  print X blanks through COUT
///   PREAD   $FB1E  read paddle X: count until its timer runs out
///   HOME    $FC58  clear the text window and home the cursor, through
///                  CLEOP1 $FC46, VTAB $FC22 / VTABZ $FC24, BASCALC $FBC1
///                  and CLEOLZ $FC9E (the game's Quit path calls it)
///   CROUT   $FD8E  print a carriage return through COUT
///   COUT    $FDED  jump through the output hook CSW ($36)
///   SETINV  $FE80  / SETNORM $FE84: set the inverse mask at $32
///
/// The game's start image has the Monitor blanked (tools/lib/t2_image.py), so
/// every instruction the game runs in $F800-$FFFF must be one of these. Each
/// runs one 6502 instruction's worth of work per call and charges that
/// instruction's cycles from the shared cycle table, so timing (and with it the
/// paddle count and where a frame ends) matches the interpreter exactly.

#include "a2n_monitor.h"

#include "apple2tc/d6502.h"

namespace {

constexpr uint16_t kCsw = 0x36;
constexpr uint16_t kInvFlag = 0x32;
constexpr uint16_t kWndLft = 0x20;
constexpr uint16_t kWndWdth = 0x21;
constexpr uint16_t kWndTop = 0x22;
constexpr uint16_t kWndBtm = 0x23;
constexpr uint16_t kCh = 0x24;
constexpr uint16_t kCv = 0x25;
constexpr uint16_t kBasL = 0x28;
constexpr uint16_t kBasH = 0x29;
constexpr uint16_t kIoStart = 0xC000;
constexpr uint16_t kPaddleTrigger = 0xC070;
constexpr uint16_t kPaddle0 = 0xC064;
constexpr uint8_t kBlank = 0xA0;
constexpr uint8_t kReturn = 0x8D;
constexpr uint8_t kInverseMask = 0x3F;
constexpr uint8_t kNormalMask = 0xFF;

/// Opcodes, only for their cycle cost in the shared table.
enum : uint8_t {
  kLdaImm = 0xA9,
  kLdaAbs = 0xAD,
  kLdaAbsX = 0xBD,
  kLdyImm = 0xA0,
  kStyZpg = 0x84,
  kJsr = 0x20,
  kRts = 0x60,
  kJmpInd = 0x6C,
  kDex = 0xCA,
  kIny = 0xC8,
  kDey = 0x88,
  kNop = 0xEA,
  kBne = 0xD0,
  kBpl = 0x10,
  kBeq = 0xF0,
  kBcc = 0x90,
  kBcs = 0xB0,
  kPha = 0x48,
  kPla = 0x68,
  kLsrA = 0x4A,
  kAslA = 0x0A,
  kAndImm = 0x29,
  kOraImm = 0x09,
  kOraZpg = 0x05,
  kAdcImm = 0x69,
  kAdcZpg = 0x65,
  kLdaZpg = 0xA5,
  kLdyZpg = 0xA4,
  kStaZpg = 0x85,
  kStaIndY = 0x91,
  kCmpZpg = 0xC5,
  kCpyZpg = 0xC4,
};

void charge(MonitorCpu &cpu, uint8_t opcode) {
  cpu.cycles += decodeOpcode(opcode).cycles;
}

uint8_t setNZ(MonitorCpu &cpu, uint8_t value) {
  cpu.regs.status = (cpu.regs.status & ~(Emu6502::STATUS_N | Emu6502::STATUS_Z)) |
      (value & Emu6502::STATUS_N) | (value == 0 ? Emu6502::STATUS_Z : 0);
  return value;
}

void push8(MonitorCpu &cpu, uint8_t value) {
  cpu.ram[Emu6502::STACK_PAGE_ADDR + cpu.regs.sp--] = value;
}

uint8_t pop8(MonitorCpu &cpu) {
  return cpu.ram[Emu6502::STACK_PAGE_ADDR + ++cpu.regs.sp];
}

void jsr(MonitorCpu &cpu, uint16_t target) {
  charge(cpu, kJsr);
  uint16_t returnAddr = cpu.regs.pc + 2;
  push8(cpu, returnAddr >> 8);
  push8(cpu, returnAddr & 0xFF);
  cpu.regs.pc = target;
}

void rts(MonitorCpu &cpu) {
  charge(cpu, kRts);
  uint16_t low = pop8(cpu);
  cpu.regs.pc = (uint16_t)((low | (pop8(cpu) << 8)) + 1);
}

void branch(MonitorCpu &cpu, uint8_t opcode, bool taken, uint16_t target) {
  charge(cpu, opcode);
  if (taken) {
    cpu.cycles += 1;
    cpu.regs.pc = target;
  } else {
    cpu.regs.pc += 2;
  }
}

void load(MonitorCpu &cpu, uint8_t opcode, uint8_t &reg, uint8_t value, uint16_t size) {
  charge(cpu, opcode);
  reg = setNZ(cpu, value);
  cpu.regs.pc += size;
}

bool zeroFlag(const MonitorCpu &cpu) {
  return (cpu.regs.status & Emu6502::STATUS_Z) != 0;
}

bool negativeFlag(const MonitorCpu &cpu) {
  return (cpu.regs.status & Emu6502::STATUS_N) != 0;
}

bool carryFlag(const MonitorCpu &cpu) {
  return (cpu.regs.status & Emu6502::STATUS_C) != 0;
}

void setCarry(MonitorCpu &cpu, bool carry) {
  cpu.regs.status = (cpu.regs.status & ~Emu6502::STATUS_C) | (carry ? Emu6502::STATUS_C : 0);
}

/// Binary-mode ADC. The routines here never run with decimal mode on; callers
/// leave such a call to the interpreter.
void adc(MonitorCpu &cpu, uint8_t opcode, uint8_t operand, uint16_t size) {
  charge(cpu, opcode);
  unsigned sum = cpu.regs.a + operand + (carryFlag(cpu) ? 1 : 0);
  bool overflow = (~(cpu.regs.a ^ operand) & (cpu.regs.a ^ sum) & 0x80) != 0;
  cpu.regs.status = (cpu.regs.status & ~Emu6502::STATUS_V) | (overflow ? Emu6502::STATUS_V : 0);
  setCarry(cpu, sum > 0xFF);
  cpu.regs.a = setNZ(cpu, (uint8_t)sum);
  cpu.regs.pc += size;
}

void compare(MonitorCpu &cpu, uint8_t opcode, uint8_t reg, uint8_t operand) {
  charge(cpu, opcode);
  setCarry(cpu, reg >= operand);
  setNZ(cpu, (uint8_t)(reg - operand));
  cpu.regs.pc += 2;
}

void storeZpg(MonitorCpu &cpu, uint8_t opcode, uint16_t addr, uint8_t value) {
  charge(cpu, opcode);
  cpu.ram[addr] = value;
  cpu.regs.pc += 2;
}

bool decimalMode(const MonitorCpu &cpu) {
  return (cpu.regs.status & Emu6502::STATUS_D) != 0;
}

} // namespace

bool a2n_monitor_step(MonitorCpu &cpu) {
  Emu6502::Regs &r = cpu.regs;
  switch (r.pc) {
  // PRBL2: LDA #$A0 / JSR COUT / DEX / BNE PRBL2 / RTS
  case 0xF94A:
    load(cpu, kLdaImm, r.a, kBlank, 2);
    return true;
  case 0xF94C:
    jsr(cpu, 0xFDED);
    return true;
  case 0xF94F:
    charge(cpu, kDex);
    r.x = setNZ(cpu, r.x - 1);
    r.pc += 1;
    return true;
  case 0xF950:
    branch(cpu, kBne, !zeroFlag(cpu), 0xF94A);
    return true;
  case 0xF952:
    rts(cpu);
    return true;

  // PREAD: trigger the timers, then count Y up while paddle X's timer runs.
  case 0xFB1E:
    charge(cpu, kLdaAbs);
    r.a = setNZ(cpu, cpu.ioRead(kPaddleTrigger));
    r.pc += 3;
    return true;
  case 0xFB21:
    load(cpu, kLdyImm, r.y, 0, 2);
    return true;
  case 0xFB23:
  case 0xFB24:
    charge(cpu, kNop);
    r.pc += 1;
    return true;
  case 0xFB25:
    charge(cpu, kLdaAbsX);
    r.a = setNZ(cpu, cpu.ioRead((uint16_t)(kPaddle0 + r.x)));
    r.pc += 3;
    return true;
  case 0xFB28:
    branch(cpu, kBpl, !negativeFlag(cpu), 0xFB2E);
    return true;
  case 0xFB2A:
    charge(cpu, kIny);
    r.y = setNZ(cpu, r.y + 1);
    r.pc += 1;
    return true;
  case 0xFB2B:
    branch(cpu, kBne, !zeroFlag(cpu), 0xFB25);
    return true;
  case 0xFB2D:
    charge(cpu, kDey);
    r.y = setNZ(cpu, r.y - 1);
    r.pc += 1;
    return true;
  case 0xFB2E:
    rts(cpu);
    return true;

  // BASCALC: text-row base address of row A into BASL/BASH.
  case 0xFBC1:
    charge(cpu, kPha);
    push8(cpu, r.a);
    r.pc += 1;
    return true;
  case 0xFBC2:
    charge(cpu, kLsrA);
    setCarry(cpu, r.a & 0x01);
    r.a = setNZ(cpu, r.a >> 1);
    r.pc += 1;
    return true;
  case 0xFBC3:
    load(cpu, kAndImm, r.a, r.a & 0x03, 2);
    return true;
  case 0xFBC5:
    load(cpu, kOraImm, r.a, r.a | 0x04, 2);
    return true;
  case 0xFBC7:
    storeZpg(cpu, kStaZpg, kBasH, r.a);
    return true;
  case 0xFBC9:
    charge(cpu, kPla);
    r.a = setNZ(cpu, pop8(cpu));
    r.pc += 1;
    return true;
  case 0xFBCA:
    load(cpu, kAndImm, r.a, r.a & 0x18, 2);
    return true;
  case 0xFBCC:
    branch(cpu, kBcc, !carryFlag(cpu), 0xFBD0);
    return true;
  case 0xFBCE:
    if (decimalMode(cpu))
      return false;
    adc(cpu, kAdcImm, 0x7F, 2);
    return true;
  case 0xFBD0:
  case 0xFBD6:
    storeZpg(cpu, kStaZpg, kBasL, r.a);
    return true;
  case 0xFBD2:
  case 0xFBD3:
    charge(cpu, kAslA);
    setCarry(cpu, r.a & 0x80);
    r.a = setNZ(cpu, (uint8_t)(r.a << 1));
    r.pc += 1;
    return true;
  case 0xFBD4:
    load(cpu, kOraZpg, r.a, r.a | cpu.ram[kBasL], 2);
    return true;
  case 0xFBD8:
    rts(cpu);
    return true;

  // VTAB: LDA CV; VTABZ: JSR BASCALC / ADC WNDLFT / STA BASL / RTS
  case 0xFC22:
    load(cpu, kLdaZpg, r.a, cpu.ram[kCv], 2);
    return true;
  case 0xFC24:
    jsr(cpu, 0xFBC1);
    return true;
  case 0xFC27:
    if (decimalMode(cpu))
      return false;
    adc(cpu, kAdcZpg, cpu.ram[kWndLft], 2);
    return true;
  case 0xFC29:
    storeZpg(cpu, kStaZpg, kBasL, r.a);
    return true;
  case 0xFC2B:
    rts(cpu);
    return true;

  // CLEOP1: clear rows A..WNDBTM-1 (PHA / JSR VTABZ / JSR CLEOLZ / LDY #0 /
  // PLA / ADC #0 / CMP WNDBTM / BCC CLEOP1 / BCS VTAB)
  case 0xFC46:
    charge(cpu, kPha);
    push8(cpu, r.a);
    r.pc += 1;
    return true;
  case 0xFC47:
    jsr(cpu, 0xFC24);
    return true;
  case 0xFC4A:
    jsr(cpu, 0xFC9E);
    return true;
  case 0xFC4D:
    load(cpu, kLdyImm, r.y, 0, 2);
    return true;
  case 0xFC4F:
    charge(cpu, kPla);
    r.a = setNZ(cpu, pop8(cpu));
    r.pc += 1;
    return true;
  case 0xFC50:
    if (decimalMode(cpu))
      return false;
    adc(cpu, kAdcImm, 0x00, 2);
    return true;
  case 0xFC52:
    compare(cpu, kCmpZpg, r.a, cpu.ram[kWndBtm]);
    return true;
  case 0xFC54:
    branch(cpu, kBcc, !carryFlag(cpu), 0xFC46);
    return true;
  case 0xFC56:
    branch(cpu, kBcs, carryFlag(cpu), 0xFC22);
    return true;

  // HOME: LDA WNDTOP / STA CV / LDY #0 / STY CH / BEQ CLEOP1
  case 0xFC58:
    load(cpu, kLdaZpg, r.a, cpu.ram[kWndTop], 2);
    return true;
  case 0xFC5A:
    storeZpg(cpu, kStaZpg, kCv, r.a);
    return true;
  case 0xFC5C:
    load(cpu, kLdyImm, r.y, 0, 2);
    return true;
  case 0xFC5E:
    storeZpg(cpu, kStyZpg, kCh, r.y);
    return true;
  case 0xFC60:
    branch(cpu, kBeq, zeroFlag(cpu), 0xFC46);
    return true;

  // CLEOLZ: LDA #$A0; CLEOL2: STA (BASL),Y / INY / CPY WNDWDTH / BCC CLEOL2 / RTS
  case 0xFC9E:
    load(cpu, kLdaImm, r.a, kBlank, 2);
    return true;
  case 0xFCA0: {
    uint16_t target = (uint16_t)((cpu.ram[kBasL] | (cpu.ram[kBasH] << 8)) + r.y);
    if (target >= kIoStart)
      return false;
    charge(cpu, kStaIndY);
    cpu.ram[target] = r.a;
    r.pc += 2;
    return true;
  }
  case 0xFCA2:
    charge(cpu, kIny);
    r.y = setNZ(cpu, r.y + 1);
    r.pc += 1;
    return true;
  case 0xFCA3:
    compare(cpu, kCpyZpg, r.y, cpu.ram[kWndWdth]);
    return true;
  case 0xFCA5:
    branch(cpu, kBcc, !carryFlag(cpu), 0xFCA0);
    return true;
  case 0xFCA7:
    rts(cpu);
    return true;

  // CROUT: LDA #$8D / BNE COUT
  case 0xFD8E:
    load(cpu, kLdaImm, r.a, kReturn, 2);
    return true;
  case 0xFD90:
    branch(cpu, kBne, !zeroFlag(cpu), 0xFDED);
    return true;

  // COUT: JMP (CSW)
  case 0xFDED:
    charge(cpu, kJmpInd);
    r.pc = (uint16_t)(cpu.ram[kCsw] | (cpu.ram[kCsw + 1] << 8));
    return true;

  // SETINV: LDY #$3F / BNE SETIFLG; SETNORM: LDY #$FF; SETIFLG: STY $32 / RTS
  case 0xFE80:
    load(cpu, kLdyImm, r.y, kInverseMask, 2);
    return true;
  case 0xFE82:
    branch(cpu, kBne, !zeroFlag(cpu), 0xFE86);
    return true;
  case 0xFE84:
    load(cpu, kLdyImm, r.y, kNormalMask, 2);
    return true;
  case 0xFE86:
    charge(cpu, kStyZpg);
    cpu.ram[kInvFlag] = r.y;
    r.pc += 2;
    return true;
  case 0xFE88:
    rts(cpu);
    return true;
  default:
    return false;
  }
}
