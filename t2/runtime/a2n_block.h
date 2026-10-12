/*
 * Derived from apple2tc include/apple2tc/system-inc.h
 * Copyright (c) Tzvetan Mikov. MIT license (see vendor/apple2tc/LICENSE).
 */

/// \file
/// What the T2 block code (t2_gN.c, from tools/lib/t2_link.py) runs against.
///
/// apple2tc's --simple-c output expects system-inc.h, which owns the CPU
/// registers and a flat 64K. In T2 the hybrid engine (a2n_engine.cpp) owns the
/// machine: the registers are shared with it, RAM is the interpreter's RAM, and
/// anything above $C000 goes through the interpreter's memory map, so the
/// Language Card and Disk II behave the same whichever side runs the code.

#pragma once

#include "apple2tc/a2engine.h"
#include "apple2tc/probe.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One compiled block: the bytes it was compiled from are
/// t2_block_bytes[bytes .. bytes + length), compared after masking with
/// t2_block_masks (0 for a self-modified operand, read at run time instead).
typedef struct {
  uint16_t addr;
  uint16_t length;
  uint8_t group;
  uint32_t bytes;
} t2_block_t;

extern const t2_block_t t2_blocks[];
extern const unsigned t2_block_count;
extern const uint8_t t2_block_bytes[];
extern const uint8_t t2_block_masks[];
extern void (*const t2_group_runs[])(void);
extern const unsigned t2_group_count;

extern uint16_t s_pc;
extern uint8_t s_a;
extern uint8_t s_x;
extern uint8_t s_y;
extern uint8_t s_status;
extern uint8_t s_sp;
/// The CPU cycle counter while a block runs, so IO sees the same count the
/// interpreter would give it.
extern unsigned s_cycles;
/// Decremented by the generated taken-branch code; unused by T2.
extern int s_remaining_cycles;
extern uint8_t *s_ram;
extern uint8_t t2_opcode_cycles[256];

uint8_t t2_io_read(uint16_t addr);
void t2_high_write(uint16_t addr, uint8_t value);
void t2_unknown_block(uint16_t pc);

#ifdef __cplusplus
}
#endif

/// Charge one instruction's base cycles before it runs, as Emu6502::runFor
/// does. The opcode byte is the compiled one: the engine checked it.
#define T2_I(addr) (s_cycles += t2_opcode_cycles[s_ram[(addr)]])

static inline uint8_t peek_zpg(uint8_t addr) {
  return s_ram[addr];
}
static inline void poke_zpg(uint8_t addr, uint8_t value) {
  s_ram[addr] = value;
}
static inline uint16_t peek16_zpg(uint8_t addr) {
  return peek_zpg(addr) + (peek_zpg((uint8_t)(addr + 1)) << 8);
}
static inline uint8_t peek(uint16_t addr) {
  if (addr >= 0xC000 && addr <= 0xCFFF)
    return t2_io_read(addr);
  return s_ram[addr];
}
static inline void poke(uint16_t addr, uint8_t value) {
  if (addr < 0xC000)
    s_ram[addr] = value;
  else
    t2_high_write(addr, value);
}
static inline uint16_t peek16(uint16_t addr) {
  return peek(addr) + (peek((uint16_t)(addr + 1)) << 8);
}

static inline void push8(uint8_t v) {
  s_ram[STACK_PAGE_ADDR + s_sp--] = v;
}
static inline uint8_t pop8(void) {
  return s_ram[STACK_PAGE_ADDR + ++s_sp];
}
static inline void push16(uint16_t v) {
  push8(v >> 8);
  push8(v);
}
static inline uint16_t pop16(void) {
  uint8_t tmp = pop8();
  return tmp + (pop8() << 8);
}

static inline uint8_t update_nz(uint8_t v) {
  s_status = (s_status & ~(STATUS_N | STATUS_Z)) | (v & STATUS_N) | (v == 0 ? STATUS_Z : 0);
  return v;
}
static inline uint8_t update_nzc(unsigned v) {
  s_status = (s_status & ~(STATUS_N | STATUS_Z | STATUS_C)) | (v & STATUS_N) |
      ((uint8_t)v == 0 ? STATUS_Z : 0) | ((v >> 8) & STATUS_C);
  return (uint8_t)v;
}
static inline uint8_t update_nz_inv_c(unsigned v) {
  return update_nzc(v ^ 0x100);
}
static inline uint8_t update_nzvc(unsigned v, uint8_t op1, uint8_t op2) {
  s_status = (s_status & ~(STATUS_N | STATUS_Z | STATUS_C | STATUS_V)) | (v & STATUS_N) |
      ((uint8_t)v == 0 ? STATUS_Z : 0) | ((v >> 8) & STATUS_C) |
      (((~(op1 ^ op2) & (op1 ^ v)) >> 1) & STATUS_V);
  return (uint8_t)v;
}
static inline uint8_t update_nzv_inv_c(unsigned v, uint8_t op1, uint8_t op2) {
  return update_nzvc(v ^ 0x100, op1, op2);
}
static inline void set_c_to_bit0(uint8_t value) {
  s_status = (s_status & ~STATUS_C) | (value & STATUS_C);
}

static inline uint8_t adc_decimal(uint8_t a, uint8_t b) {
  uint8_t c = s_status & STATUS_C;
  uint8_t al = (a & 15) + (b & 15) + c;
  if (al >= 10)
    al += 6;
  uint8_t ah = (a >> 4) + (b >> 4) + (al > 15);

  s_status &= ~(STATUS_N | STATUS_V | STATUS_Z | STATUS_C);
  if (!(uint8_t)(a + b + c))
    s_status |= STATUS_Z;
  else if (ah & 8)
    s_status |= STATUS_N;

  if (~(a ^ b) & (a ^ (ah << 4)) & 0x80)
    s_status |= STATUS_V;

  if (ah >= 10)
    ah += 6;
  if (ah > 15)
    s_status |= STATUS_C;

  return (ah << 4) | (al & 15);
}

static inline uint8_t sbc_decimal(uint8_t a, uint8_t b) {
  uint8_t c = ~s_status & STATUS_C;
  uint8_t al = (a & 15) - (b & 15) - c;
  if ((int8_t)(al) < 0)
    al -= 6;
  uint8_t ah = (a >> 4) - (b >> 4) - ((int8_t)(al) < 0);

  s_status &= ~(STATUS_N | STATUS_V | STATUS_Z | STATUS_C);
  uint16_t diff = a - b - c;
  if (!(uint8_t)diff)
    s_status |= STATUS_Z;
  else if (diff & 0x80)
    s_status |= STATUS_N;

  if ((a ^ b) & (a ^ diff) & 0x80)
    s_status |= STATUS_V;
  if (!(diff & 0xff00))
    s_status |= STATUS_C;
  if ((int8_t)ah < 0)
    ah -= 6;
  return (ah << 4) | (al & 15);
}
