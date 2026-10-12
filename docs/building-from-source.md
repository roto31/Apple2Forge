# Building from source

You can build the emulator and the app yourself. The build downloads the upstream emulator source (apple2tc), applies this project's patches, and assembles `Apple2Forge.app`. ROMs are needed only to run the build's checks; nothing from them goes into the app.

## Prerequisites

- macOS 14 or later.
- Xcode or the Xcode Command Line Tools, for `clang++`, `swift`, `git` and `perl`.
- `cmake` and `python3`: `brew install cmake python3` if `tools/00_setup.sh` reports them missing.

## Steps

```bash
git clone https://github.com/roto31/Apple2Forge.git
cd Apple2Forge

tools/00_setup.sh                              # 1. check the toolchain, clone + build apple2tc at the pinned commit
tools/05_fetch_rom.sh --install                # 2. Apple ][+ ROM (used by the build checks, and by the app)
tools/05_fetch_rom.sh --model=iie --install    #    Apple //e ROMs (optional; for 128K titles)
tools/15_build_a2emu_norom.sh                  # 3. patched emulator: build/a2emu-norom/a2emu
tools/60_build_app.sh                          # 4. build/Apple2Forge.app
open build/Apple2Forge.app
```

Each script prints a gate for every step (PASSED or FAILED), stops at the first failure, and ends with a summary table. Every script has `--help`, and most have `--dry-run`. Logs go to `work/_logs/`.

### 1. `tools/00_setup.sh`

Checks for `git`, `cmake`, `clang++`, `swift`, `python3` and `perl`. Then it clones [tmikov/apple2tc](https://github.com/tmikov/apple2tc) into `vendor/apple2tc/` at the commit pinned in `vendor/apple2tc.COMMIT`, builds it, and checks that `apple2tc` and `a2emu` start. Safe to re-run. `--update` moves the pin to the latest upstream commit.

### 3. `tools/15_build_a2emu_norom.sh`

Exports the pinned source into `vendor/apple2tc-norom-src/` (regenerated every run, never edited by hand) and applies the patches in `vendor/patches/` in this order:

| Patch | What it changes |
|---|---|
| `a2emu-require-rom.patch` | Removes the built-in Apple ][+ ROM; the emulator needs `--rom=PATH` |
| `a2emu-language-card.patch` | Adds a 16K Language Card (64K Apple ][+) |
| `a2emu-lc-snapshot.patch` | Saves and restores the Language Card in snapshots |
| `a2emu-disk-control.patch` | `--disk2=PATH`, and `--control-fd=N` for `mount`/`eject` commands while running |
| `a2emu-iie.patch` | `--model=iie`: enhanced Apple //e (128K, 65C02, 80 columns, video ROM), Open/Solid Apple, arrow keys |
| `a2emu-snapshot-frame.patch` | `--snapshot-frame=N` for scripted captures |
| `a2emu-disk-order.patch` | Detects ProDOS-order `.dsk` images |
| `a2emu-menu-bar.patch` | Makes the game window a non-activating panel, so Apple2Forge keeps the menu bar |

It then builds `a2emu` and checks the result:
- no ROM bytes are inside it
- `--help` works
- it refuses to start without a ROM
- with a ROM, it boots to the Applesoft `]` prompt
- a snapshot restores correctly

### 4. `tools/60_build_app.sh`

Builds the Swift package in `app/Apple2Forge/` (`swift build -c release`) and assembles `build/Apple2Forge.app`. It copies in `a2emu` and the library scripts and rules: the download, catalog and compatibility-check scripts and their `library/*.json` rules. Then it checks that no ROM or disk image is in the bundle, and ad-hoc signs it. An existing app is moved to `build/Apple2Forge.backup-<time>.app` first.

## Running from the build folder

A development build run from the repository (`swift run` in `app/Apple2Forge/`) finds the scripts and `build/a2emu-norom/a2emu` in the repository itself. A built `.app` uses the copies in its `Contents/Resources/`.

## Tests

```bash
(cd app/Apple2Forge && swift test)                 # Swift unit tests (catalog, launch arguments, locations)
python3 -m unittest discover -s tests -p 'test_*.py'   # Python unit tests (analyzer, catalog, compatibility check)
tests/stage6_iie_gate.sh                          # //e emulation (needs the //e ROMs)
tests/stage6_disk_swap.sh                         # disk mount/eject while running
tests/stage6_disk_order_gate.sh                   # ProDOS-order images
tests/stage6_library_gate.sh                      # the app end to end (needs a downloaded library)
```

The `stage1`–`stage5` gates test the [command-line tools](command-line-tools.md) and need your own copy of the disk they were written for.
