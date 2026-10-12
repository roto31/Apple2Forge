# Command-line tools

Everything Apple2Forge does is done by scripts in `tools/`, which also work on their own: the library download, catalog and compatibility check, and the [native conversion toolkit](native-conversion.md) that its **Build** tab runs. The toolkit wraps a single Apple ][+ disk image you own into a Mac app, which needs your own Apple II+ ROM installed on the Mac that runs it. The step-by-step guide, with limits, is [Make a Mac app from your disk](make-a-mac-app-from-your-disk.md). Every script has `--help`; most have `--dry-run`.

> **Personal use only.** An app built from a disk image contains the software on that disk, which is copyrighted. Don't share apps you build, or the disk images in them.

## Setup and build

| Script | Purpose |
|---|---|
| `tools/00_setup.sh` | Checks the toolchain; clones and builds apple2tc at the pinned commit |
| `tools/05_fetch_rom.sh [--model=iiplus\|iie] [--install]` | Downloads and assembles the Apple II ROMs; `--install` copies them where the apps look. See [Installing ROMs](installing-roms.md) |
| `tools/15_build_a2emu_norom.sh` | Builds the patched, ROM-free emulator: `build/a2emu-norom/a2emu` |
| `tools/60_build_app.sh [--release]` | Builds `build/Apple2Forge.app`, which records this checkout as its project folder. `--release` builds `build/release/Apple2Forge.app` for distribution instead: no project folder recorded, debug symbols stripped, and the build fails if a path from this Mac is inside |

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
| `--build=DISK [--t2]` | Runs the Build tab's pipeline on `DISK` without a window, prints each stage and the compatibility report, then exits: 0 when Analyze and Wrap (T1) pass, and with `--t2` the T2 stages too |
| `--project=DIR` | Uses `DIR` as the project folder (a checkout of this repository) for this run |
| `--builds-dir=DIR` | Writes builds to `DIR` instead of `~/Library/Application Support/Apple2Forge/builds/` |
| `--drop=PATH` | Starts normally, then queues `PATH` as a drop on the Build tab does (repeatable; with `--t2`, tries T2) |
| `--quit-after-build=S` | Quits `S` seconds after the build queue empties (for tests) |
| `--defaults-suite=NAME` | Keeps settings in a separate defaults domain (for tests) |

See [Apple2Forge: Command line](apple2forge.md#command-line).

## The emulator: `a2emu`

`build/a2emu-norom/a2emu` can be run directly:

```bash
ROMS="$HOME/Library/Application Support/Apple2Forge/roms"
build/a2emu-norom/a2emu --rom="$ROMS/apple2plus.rom" --disk1=game.dsk
build/a2emu-norom/a2emu --model=iie --rom="$ROMS/apple2e-enhanced.rom" --video-rom="$ROMS/apple2e-video.rom" \
    --disk1=side-a.dsk --disk2=side-b.dsk
```

With `--control-fd=0`, it reads `mount D PATH` and `eject D` lines from standard input while running. This is how the Disk menu works: see [Signal flow](signal-flow.md#disk-swap).

Options Apple2Forge sets from its Settings window:

| Option | Effect |
|---|---|
| `--display=smooth\|classic` | Smooth (the default): sharp scaling and clean hi-res colour. Classic: the original picture with colour fringes. See [Technical references](references.md#display-styles) |
| `--controls=fade\|always\|hidden` | The floating buttons over the picture: shown when the mouse moves (the default), always shown, or never shown |
| `--no-sound` | Starts with the sound off; the Sound button turns it on |
| `--joystick` | Starts with the arrow keys driving the joystick (F7 switches) |
| `--fast` | Runs at five times the normal speed |

## Turning a disk you own into a Mac app

### T1: emulator wrap

The original program runs unchanged in an emulator built into the app.

```bash
tools/10_analyze.sh "My Disk.dsk"                    # read-only analysis → work/<disk>/analysis.json + analysis.md
tools/20_wrap_t1.sh "My Game side A.dsk" "My Game side B.dsk" --name "My Game"   # → work/<disk>/t1/My Game.app
tools/20_wrap_t1.sh "My Disk.dsk" --model auto --rom-dir "$HOME/Library/Application Support/Apple2Forge/roms"
```

Pass every side of the title; the helper `tools/lib/t1_disk_set.py` orders them and writes `disks.tsv` into the app. `--model=auto` (default) picks Apple ][+ vs enhanced //e; `--rom-dir` is where those boot tests read ROMs from (the same folder the app uses at launch). An existing app with the same name is first moved to `<name>.app.backup-<time>`.

```bash
tools/25_check_t1.sh "work/<disk>/t1/My Game.app"  # headless boot check on the Apple ][+; exit 0 boots, 1 not, 2 can't check
```

The boot check shows whether the disk starts, not whether the program works. T1 emulates the Apple ][+ only, holds one disk, and doesn't save. Full steps, limits and measured results: [Make a Mac app from your disk](make-a-mac-app-from-your-disk.md).

### T2-hybrid: recompiled to native code

[apple2tc](https://github.com/tmikov/apple2tc) translates the game's 6502 code to C, which is compiled natively; a built-in 6502 interpreter runs anything not covered. These scripts are written for MECC's *Number Munchers* v1.3 and need your own copy of that disk:

```bash
tools/30_capture.sh            # snapshots of the machine at known points, and the code executed
tools/40_coverage.sh --sessions tests/fixtures/stage4 --sessions tests/fixtures/stage5 --jobs 4   # scripted play sessions
tools/50_recompile.sh --jobs 8 # apple2tc → C → native build, then frame-by-frame comparison with a2emu
tools/55_wrap_t2.sh            # → work/<disk>/t2/<name> (T2-hybrid).app
```

The T2-hybrid app needs no ROM. In it, the game's **Quit** restarts at the title screen instead of rebooting the disk.

`tools/t2/profiles.json` lists the disks T2 is attempted for, matched by SHA-256, with the play sessions `40_coverage.sh` replays. The Build tab offers **Try T2** only for these. It has one entry, the Number Munchers v1.3 4am crack. See [T2 for another disk](native-conversion.md#t2-for-another-disk).

### Recording your own play session

```bash
tools/45_record.sh "My Disk.dsk"                         # play in a window, then close it → work/<disk>/recordings/<time>/
tools/45_record.sh "My Disk.dsk" --out DIR --replay      # replay DIR/session.keys from boot and compare
```

The recorder runs `a2emu` with key tracing and code collection. When the window closes, `record.md` reports the keys and the executed bytes per memory region. The report appears then, not live. **Replay** says whether exactly the recorded code ran again. This is the first step towards a T2 profile, and it is what the Build tab's **Record Coverage…** runs.

All generated files (analysis, captures, C code, apps) stay in the `work/` folder, which Git ignores.

The stages and their data flow are diagrammed in [Signal flow](signal-flow.md#t1-and-t2-build-stages). The Number Munchers results are in [Native conversion toolkit](native-conversion.md#case-study-number-munchers).
