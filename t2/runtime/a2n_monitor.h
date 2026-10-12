/// \file
/// The Apple II Monitor routines Number Munchers calls, in C, so T2 needs no
/// ROM. See a2n_monitor.cpp.

#pragma once

#include "apple2tc/emu6502.h"

#include <cstdint>

/// What a Monitor instruction may touch: the registers, the cycle counter,
/// RAM, and IO reads (the paddle timers).
struct MonitorCpu {
  Emu6502::Regs regs;
  unsigned cycles;
  uint8_t *ram;
  uint8_t (*ioRead)(uint16_t addr);
};

/// Run the one instruction at cpu.regs.pc if it belongs to a Monitor routine
/// T2 provides, and return true; otherwise return false and change nothing.
bool a2n_monitor_step(MonitorCpu &cpu);

/// Whether \p pc is in the Monitor's address range ($F800-$FFFF), where T2's
/// start image holds no code.
inline bool a2n_monitor_range(uint16_t pc) {
  return pc >= 0xF800;
}
