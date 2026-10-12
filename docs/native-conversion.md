# Native conversion toolkit

The toolkit is the core of this repository: numbered scripts in `tools/` that take an Apple II disk image you own and turn it into a Mac app. [Apple2Forge](apple2forge.md), the bundled app, runs these same scripts from its **Build** tab.

The worked example throughout is MECC's *Number Munchers* v1.3 (MECC A-170). It is the only disk taken through every stage.

> **Personal use only.** An app built from a disk image contains the software on that disk, which is copyrighted. Don't share apps you build, or the disk images in them. See [Legal and ROMs](legal-and-roms.md).

## Tiers

| Tier | What runs | Works for | Needs at run time |
|---|---|---|---|
| **T1**: emulator wrap | The original 6502 program, unchanged, in the patched `a2emu` emulator inside the app (Apple ][+ with a 16K Language Card) | Any 140K `.dsk`, `.do` or `.po` disk the analyzer supports. Whether it *runs* depends on the disk: check it with the [boot check](make-a-mac-app-from-your-disk.md#4-check-that-it-boots) | Your Apple II+ ROM installed on that Mac |
| **T2-hybrid**: recompiled | The program's 6502 code translated to C by [apple2tc](https://github.com/tmikov/apple2tc) and compiled to native arm64. A built-in 6502 interpreter runs any code that wasn't translated. Graphics, sound, keyboard and the Disk II are still emulated hardware | Number Munchers v1.3 (4am crack) only | No ROM |

A full rewrite into native Mac code (sometimes called T3) was not attempted.

## Stages

Each stage is one script. Each stops at the first failed check and ends with a summary table. Generated files go to `work/<disk>/`, which Git ignores.

| Stage | Script | Produces | General or Number Munchers only |
|---|---|---|---|
| 0 Toolchain | `tools/00_setup.sh` | apple2tc cloned and built at the pinned commit | General |
| 1 Analyze | `tools/10_analyze.sh DISK` | `analysis.json`, `analysis.md`: format, sector order, filesystem, catalog, boot sector, loader, copy-protection hints (track 0 only) | General |
| 2 T1 wrap | `tools/20_wrap_t1.sh DISK` | `t1/<name>.app` | General |
| 2 Boot check | `tools/25_check_t1.sh APP` | Whether the T1 app's disk starts | General |
| 3 Capture | `tools/30_capture.sh` | Machine snapshots at known points, disk-read log, ROM and soft-switch use | Number Munchers addresses |
| 4 Coverage | `tools/40_coverage.sh` | Scripted play sessions replayed headless; executed code per region | Number Munchers sessions |
| 4 Record | `tools/45_record.sh DISK` | Your own play session: keys and the code that ran, with a replay check | General |
| 5 Recompile | `tools/50_recompile.sh` | C from apple2tc, the native `a2n-t2` build, frame-by-frame comparison with `a2emu` | Number Munchers (title address, Monitor routines, level solver) |
| 5 T2 wrap | `tools/55_wrap_t2.sh` | `t2/<name> (T2-hybrid).app` | Number Munchers |

Commands and options: [Command-line tools](command-line-tools.md). Diagram: [Signal flow: T1 and T2 build stages](signal-flow.md#t1-and-t2-build-stages).

## Case study: Number Munchers

These results were measured on the maintainer's Mac (macOS, arm64) on 2026-10-11, by the gate scripts in `tests/`. The gates need your own copy of the disk, so they can't be run without it.

### Stage 1: analysis

- Custom MECC loader, entry point `$3000`, already cracked (all 7 known 4am patches present), 3 catalog entries, DOS 3.3 sector order.
- The boot sector switches in the Language Card and checks for 64K before jumping to `$3000`.

### Stage 2: T1

- The original MECC loader stopped with "THIS DISKETTE REQUIRES AT LEAST 64K OF RAM", because upstream `a2emu` is a 48K Apple ][+. A Language Card patch (16K, two `$D000` banks) fixed it.
- The upstream emulator has Apple's 12K system ROM compiled in. The patched build has none of its 48 256-byte blocks and refuses to start without `--rom=`.
- The T1 app (640K) boots to the title screen in a 560×416 window. Text recognition reads "Do you want to play Number Munchers with a joystick?".
- As an independent check, the separate emulator Virtual ][ booted the same bundled disk to a Number Munchers screen.

### Stages 3 and 4: capture and coverage

- The game was captured at four points from boot to its first board. A restored capture replays the next disk load byte for byte.
- Each game mode loads its own code into Language Card RAM (`$D000–$F1FF`), overwriting the previous mode's.
- 11 scripted sessions (the six game modes, Information, Hall of Fame, Quit, instructions, joystick) replay identically on every run. They executed 87.2% of `$0800–$1FFF` and 83.1% of the card-RAM code. The rest of the loaded bytes are mostly data and the loader.

### Stage 5: T2-hybrid

apple2tc only translates code that ran in a recorded session, and this game rewrites its own code. In each of its 55 overlay groups, 1,686–2,578 instruction starts are targets of the game's own stores. Each compiled block therefore checks that memory still holds the bytes it was translated from, and falls back to the interpreter if not.

| Check | Result |
|---|---|
| 17 recorded sessions, replayed in `a2emu` (real ROM) and in the T2 build | **Identical**: every frame hash and the probe log, 153,202 frames |
| 16 random-key sessions × 400 keys, on paths nobody recorded | **Identical**: 472,305 frames |
| Share of instructions run as native code | 99.57% or more in recorded sessions, 99.02% or more in random-key sessions. No recorded instruction ran uncompiled |
| Levels cleared, each in an equivalent session | Multiples 12, Factors 12, Primes 12, Equality 12, Inequality 8, Let the computer decide 12 |
| ROM in the app | None. The Monitor routines the game calls (`COUT`, `HOME`, `VTAB` and others) are C written from their documented behaviour |

What apple2tc couldn't do alone, and how it was worked around:

- **The game writes into a block apple2tc already translated.** Every instruction the game writes to now starts a new block, so the block's byte check catches the change.
- **Branches that land inside an instruction** (a `BIT` skip) aren't decoded by apple2tc. They're added as extra entry points.
- **Long expressions are truncated** by apple2tc's C writer. Those blocks are left to the interpreter.

**Known difference.** The game's **Quit** reboots through the slot 6 boot PROM, which the T2 build doesn't have. T2 restarts at the title screen instead.

### Limits

- **Native share is measured per session, not per byte of the game.** Code that no session reached still runs, but in the interpreter. Teacher settings and real joystick play were never run.
- **Sound wasn't compared.** Frame hashes cover video only. The speaker uses the same emulated hardware code in both builds.
- **Saves stay in memory.** Neither T1 nor T2 writes back to the disk image.
- arm64 only, ad-hoc signed, not notarized. The window is titled "a2emu" (T1) or "a2n-t2" (T2).

## T2 for another disk

The Stage 3–5 scripts take their addresses and play sessions from the Number Munchers work. A T2 build is attempted only for disks listed in `tools/t2/profiles.json`, which matches disks by SHA-256. It has one entry, the Number Munchers v1.3 4am crack.

Adding a disk is manual work:

1. Record coverage with `tools/45_record.sh`.
2. Find a stable start-screen address.
3. Write C versions of the Monitor routines the program calls.
4. Add a profile.

Nobody has done this for a second disk yet.

## See also

- [Make a Mac app from your disk](make-a-mac-app-from-your-disk.md): T1 step by step, with boot-check results for 11 disks.
- [Apple2Forge](apple2forge.md): the same pipeline from a drag-and-drop window.
- [Architecture](architecture.md) and [Signal flow](signal-flow.md).
