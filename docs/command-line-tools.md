# Command-line tools

Everything Apple2Forge does with the library is done by scripts in `tools/`, which also work on their own. There are also tools that turn a single disk image you own into a standalone Mac app. Every script has `--help`; most have `--dry-run`.

> **Personal use only.** An app built from a disk image contains the software on that disk, which is copyrighted. Don't share apps you build, or the disk images in them.

## Setup and build

| Script | Purpose |
|---|---|
| `tools/00_setup.sh` | Checks the toolchain; clones and builds apple2tc at the pinned commit |
| `tools/05_fetch_rom.sh [--model=iiplus\|iie] [--install]` | Downloads and assembles the Apple II ROMs; `--install` copies them where the apps look. See [Installing ROMs](installing-roms.md) |
| `tools/15_build_a2emu_norom.sh` | Builds the patched, ROM-free emulator: `build/a2emu-norom/a2emu` |
| `tools/60_build_app.sh` | Builds `build/Apple2Forge.app` |

Details: [Building from source](building-from-source.md).

## Library

These are the scripts the app runs. Defaults point at `~/Library/Application Support/Apple2Forge/library/`.

| Script | Purpose |
|---|---|
| `tools/07_fetch_edu_library.sh [--dest=DIR] [--limit=N] [--progress=json] [--no-dashboard]` | Downloads the educational `.dsk` images into `DIR/disks/` and writes `DIR/manifest.json`. It resumes where it stopped. Without `--no-dashboard` it also serves a progress page on `http://localhost:8765` |
| `tools/50_library.sh [--library=DIR] [--rules=DIR]` | Builds `DIR/library.json`: groups disks into titles and assigns subjects and machines |
| `tools/55_compat_sweep.sh [--library=DIR] [--emulator=PATH] [--rom-dir=DIR] [--frames=N] [--limit=N]` | Boots each title without a window to decide whether it needs an Apple ][+ or a //e; writes `DIR/compat.json`. Run `50_library.sh` again afterwards to use the results |

Example: a small test library of 20 images in a temporary folder:

```bash
tools/07_fetch_edu_library.sh --dest=/tmp/a2lib --limit=20 --no-dashboard
tools/50_library.sh --library=/tmp/a2lib
tools/55_compat_sweep.sh --library=/tmp/a2lib --rom-dir="$HOME/Library/Application Support/Apple2Forge/roms"
tools/50_library.sh --library=/tmp/a2lib
```

## Apple2Forge command-line modes

The app binary has modes for scripting and testing. Run it as `Apple2Forge.app/Contents/MacOS/Apple2Forge`:

| Option | Effect |
|---|---|
| `--dump-menu` | Prints the Library menu as indented text and exits |
| `--print-library` | Prints the library folder in use and exits |
| `--set-library=DIR` | Checks and remembers `DIR` as the library folder, then exits |
| `--library=DIR` | Uses `DIR` for this run only |
| `--download-to=DIR [--limit=N]` | Runs download, then catalog, then compatibility check into `DIR`, printing progress, then exits |
| `--print-launch=TITLE_ID` | Prints the emulator arguments for a title and exits |
| `--launch=TITLE_ID` | Starts normally, then starts the title, as the Library menu does |
| `--swap-after=S:D:PATH` | `S` seconds after start, inserts `disks/PATH` into drive `D`, as the Disk menu does |
| `--defaults-suite=NAME` | Keeps settings in a separate defaults domain (for tests) |

## The emulator: `a2emu`

`build/a2emu-norom/a2emu` can be run directly:

```bash
ROMS="$HOME/Library/Application Support/Apple2Forge/roms"
build/a2emu-norom/a2emu --rom="$ROMS/apple2plus.rom" --disk1=game.dsk
build/a2emu-norom/a2emu --model=iie --rom="$ROMS/apple2e-enhanced.rom" --video-rom="$ROMS/apple2e-video.rom" \
    --disk1=side-a.dsk --disk2=side-b.dsk
```

With `--control-fd=0`, it reads `mount D PATH` and `eject D` lines from standard input while running. This is how the Disk menu works: see [Signal flow](signal-flow.md#disk-swap).

## Turning a disk you own into a Mac app

### T1: emulator wrap

The original program runs unchanged in an emulator built into the app.

```bash
tools/10_analyze.sh "My Disk.dsk"                    # read-only analysis → work/<disk>/analysis.json + analysis.md
tools/20_wrap_t1.sh "My Disk.dsk" --name "My Game"   # → work/<disk>/t1/My Game.app
```

The app loads `apple2plus.rom` from `~/Library/Application Support/Apple2Forge/roms/` each time it starts, and shows an alert if the file is missing. An existing app with the same name is first moved to `<name>.app.backup-<time>`.

### T2-hybrid: recompiled to native code

[apple2tc](https://github.com/tmikov/apple2tc) translates the game's 6502 code to C, which is compiled natively; a built-in 6502 interpreter runs anything not covered. These scripts are written for MECC's *Number Munchers* v1.3 and need your own copy of that disk:

```bash
tools/30_capture.sh            # snapshots of the machine at known points, and the code executed
tools/40_coverage.sh --sessions tests/fixtures/stage4 --sessions tests/fixtures/stage5 --jobs 4   # scripted play sessions
tools/50_recompile.sh --jobs 8 # apple2tc → C → native build, then frame-by-frame comparison with a2emu
tools/55_wrap_t2.sh            # → work/<disk>/t2/<name> (T2-hybrid).app
```

The T2-hybrid app needs no ROM. In it, the game's **Quit** restarts at the title screen instead of rebooting the disk.

All generated files (analysis, captures, C code, apps) stay in the `work/` folder, which Git ignores.

The stages and their data flow are diagrammed in [Signal flow](signal-flow.md#t1-and-t2-build-stages).
