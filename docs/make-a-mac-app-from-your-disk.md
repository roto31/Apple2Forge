# Make a Mac app from your disk

Developer tools in this repository can wrap an Apple ][+ disk image you own into a Mac app (a **T1** app). Double-click the app and the disk boots in the emulator built into it, in its own window, with no other setup.

This page covers what you get, what it needs, the exact steps, how to check the result, and the limits. Read [What a T1 app is not](#what-a-t1-app-is-not) before you rely on one.

> **Personal use only.** The app contains the software on your disk, which is copyrighted by its publisher. Don't share apps you build, or the disk images in them. See [Legal and ROMs](legal-and-roms.md).

## What you get

`work/<disk>/t1/<App Name>.app`, built on your Mac, containing:

| Part | Where in the app |
|---|---|
| A launcher script, which starts the emulator | `Contents/MacOS/launcher` |
| The patched emulator `a2emu` (Apple ][+ with a 16K Language Card, 64K) | `Contents/MacOS/a2emu` |
| Boot disk and any other sides | `Contents/Resources/disk.dsk`, `side-02.dsk`, … and `disks.tsv` |
| A personal-use notice and the emulator's licences | `Contents/Resources/NOTICE.txt`, `Contents/Resources/licenses/` |

The app is ad-hoc signed. Its `Info.plist` records the disk's SHA-256.

There is **no Apple system ROM** in the app. Each time the app starts, it reads the ROMs for the machine recorded in the app (`A2NMachine` in `Info.plist`): Apple II+ from `apple2plus.rom`, or enhanced Apple //e from `apple2e-enhanced.rom` and `apple2e-video.rom`, all under `~/Library/Application Support/Apple2Forge/roms/`. If a file is missing or the wrong size, it shows an alert and quits.

Like Apple2Forge, the emulator inside does contain two small pieces of Apple-derived firmware data from upstream apple2tc: the 256-byte Disk II boot PROM and a 2 KB text font. See [third-party notices](../THIRD_PARTY_NOTICES.md#apple-firmware).

## What a T1 app is not

- **Not standalone.** It runs only on a Mac that has your Apple II+ ROM installed at the path above. Copying the app alone to another Mac gives the "Apple II ROM not found" alert.
- **Apple ][+ or enhanced //e.** With `--model=auto` (the default), the wrap step test-boots your disk on both machines and picks the same way the library sweep does. Use `--model=iiplus` or `--model=iie` to force one machine.
- **Read-only disks, live swapping.** Every side you pass is bundled read-only. The **Disk** menu and the overlay **Disk** button insert any bundled side (or another 140K image you choose) into drive 1 or 2 while the program runs.
- **Read-only.** Nothing is saved: scores, records and files written by the program are lost when you quit.
- **Not tested on every disk.** Only Number Munchers has passed the full automated checks, which include a real windowed launch and a comparison against another emulator. For any other disk, use the [boot check](#4-check-that-it-boots) and try it yourself.
- **Window title.** The window is titled "a2emu", not the app name.

## Requirements

- A Mac set up as in [Building from source](building-from-source.md#prerequisites): macOS 14 or later, the Xcode Command Line Tools, `cmake` and `python3`.
- Your own disk image: a 140K (143,360-byte) `.dsk`, `.do` or `.po` file, in DOS 3.3 or ProDOS sector order. `.nib`, `.woz` and `.2mg` images are rejected.
- Your own Apple II+ ROM: see [Installing ROMs](installing-roms.md).

## Steps

Run these from the repository folder.

### 1. Set up once

```bash
tools/00_setup.sh                 # toolchain check; clones and builds apple2tc at the pinned commit
tools/05_fetch_rom.sh --install   # Apple II+ ROM into roms/ (used by the build checks) and into
                                  # ~/Library/Application Support/Apple2Forge/roms/ (used by the app)
tools/15_build_a2emu_norom.sh     # patched, ROM-free emulator: build/a2emu-norom/a2emu
```

### 2. Check the disk (optional)

```bash
tools/10_analyze.sh "My Disk.dsk"
```

This only reads the disk. It writes `work/<disk>/analysis.json` and a readable `analysis.md` covering the format, sector order, filesystem, catalog and boot sector. The wrap step runs it for you if you skip it.

### 3. Build the app

```bash
tools/20_wrap_t1.sh "My Disk.dsk" --name "My Game"
```

The output is `work/my-disk/t1/My Game.app`; the folder name is the disk file name in lower case with dashes. Without `--name`, the app is named after the disk file. The script stops at the first failed gate:

| Gate | Checks |
|---|---|
| 0: Inputs | The disk is readable; the emulator, ROM, launcher and licence files are present; the emulator has the Language Card patch |
| 1: Analysis | The analyzer marks the disk supported and it is exactly 143,360 bytes |
| 2: Assemble bundle | The app is assembled in a staging folder and its `Info.plist` is valid |
| 3: No ROM in bundle | No 256-byte block of the Apple II+ system ROM appears in any file in the app |
| 4: Sign + verify | Ad-hoc signature, then `codesign --verify --strict --deep` |
| 5: Install | The app moves into place. An existing app of the same name is first renamed `<name>.app.backup-<time>` |

`--dry-run` runs gates 0 and 1 only, and builds nothing. The log is in `work/_logs/20_wrap_t1.log`.

### 4. Check that it boots

```bash
tools/25_check_t1.sh "work/my-disk/t1/My Game.app"
```

This runs the app's own emulator and disk without a window on the Apple ][+, using your installed ROM, and looks at the screen after 30 seconds (up to 2 minutes if the screen is still blank). It uses the same rules as the library's compatibility check:

- It **passes** if the screen shows graphics, or text that isn't an error.
- It **fails** if the screen is blank, shows an error, a machine-requirement message or a bare `]`, `*` or `>` prompt, or the boot never got past the Disk II boot ROM.
- Exit codes: 0 boots, 1 did not boot, 2 could not check (for example, an app built with an emulator older than this check).

A pass means the disk **starts**. It doesn't play the program. Open the app and try it.

### 5. Open it

Double-click the app in the Finder, or run `open "work/my-disk/t1/My Game.app"`. An app you built yourself opens without the Gatekeeper prompt. A copy brought to another Mac by download or AirDrop is quarantined by macOS and needs the [first-launch steps](getting-started.md#first-launch) there, and that Mac needs the ROM installed.

The keyboard, joystick mode (F7) and display keys (F3–F6) work as in [Playing games](playing-games.md). Close the window to quit. The emulator's messages go to `~/Library/Logs/Apple2Forge/<App Name>.log`.

## Using the Build tab instead

[Apple2Forge](apple2forge.md#build-tab)'s **Build** tab runs the same steps without Terminal:

1. Do step 1 above once.
2. Build the app with `tools/60_build_app.sh` and open `build/Apple2Forge.app`. A downloaded Apple2Forge works too: choose the checkout in **Apple2Forge ▸ Settings… ▸ Project folder**.
3. Drop the disk on the Build tab. Analyze and Wrap (T1) run automatically, and the card shows a compatibility report.
4. Choose **Export T1 App…**.

![A finished Build tab card for a disk: stage results, compatibility report, and the Export T1 App button](images/build-tab-reports.png)

The same `tools/20_wrap_t1.sh` builds the app, so everything on this page applies, including the limits. Run the [boot check](#4-check-that-it-boots) on the exported app.

## Results so far

The boot check was run on 2026-10-11 against every T1 app built on the maintainer's Mac (12 apps from 10 disks), and then on Music Theory, which was built for this page: 11 disks in all, 9 of which start. Disks are named as they appear in the [Asimov archive](credits.md#educational-software).

| Disk | Boot check | Screen at check time |
|---|---|---|
| MECC-A170 Number Munchers | Boots | Hi-res graphics |
| MECC-A170 Number Munchers v1.3 (4am crack) | Boots | Hi-res graphics |
| MECC-A712 Music Theory (built for this page) | Boots | Hi-res graphics; the windowed app also showed the title screen |
| MECC-A733 Elementary Vol. 9 v1.0 | Boots | Text: "ELEMENTARY VOLUME 9" |
| Checkerboard Trails (1988, Focus Media) | Boots | Hi-res graphics |
| Perplexing Puzzles tutorial | Boots | Hi-res graphics |
| SCHOLASTIC_MICROZINE_01_D2S1 | Boots | Hi-res graphics |
| Tom's Math Drill and other programs | Boots | Text: "INITIALIZED 1-25-89" |
| Word Attack Skills - SAT Roots | Boots | Hi-res graphics |
| Computer Connections Spreadsheet Level 4-6, side A | **Does not boot** | "MENU_INIT ERROR". The title needs an Apple //e, so it can't run in T1 |
| physik3 | **Does not boot** | Stops at a `]` prompt. The library's own check couldn't boot it on either machine |

One older app of the Number Munchers 4am crack was built before the boot check existed and reports "could not check". Rebuilding it fixes that.

"Boots" here means the disk started and showed a non-error screen. Only Number Munchers has also been played through automated sessions.

## Rebuilding and removing

- **Rebuild:** run step 3 again, for example after updating the emulator with `tools/15_build_a2emu_norom.sh`. The previous app is kept as a `.backup-<time>` copy. Apps built before an emulator fix don't get the fix until they're rebuilt.
- **Remove:** delete the `.app` and, if you want, the `work/<disk>/` folder. Nothing else is installed. The ROM in `~/Library/Application Support/Apple2Forge/roms/` is shared with Apple2Forge.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `Missing build/a2emu-norom/a2emu …` (gate 0) | Run `tools/15_build_a2emu_norom.sh`, or `tools/00_setup.sh` first on a new checkout |
| `Missing roms/apple2plus.rom …` (gate 0) | Run `tools/05_fetch_rom.sh --install`, or put your ROM there by hand: see [Installing ROMs](installing-roms.md#option-2-by-hand) |
| `… predates the Language Card patch` (gate 0) | Rebuild the emulator with `tools/15_build_a2emu_norom.sh` |
| `Stage 1 marks this disk unsupported` (gate 1) | The reason is in `work/<disk>/analysis.md`. Usually the image is `.nib`, `.woz` or `.2mg`, or the wrong size |
| `Disk is not a 140K sector image` (gate 1) | Only 143,360-byte images are supported |
| `ROM content found in the bundle` (gate 3) | A file in the app contains Apple ROM bytes, so don't use or share this build. Report it as a bug |
| Alert "Apple II ROM not found" when opening the app | Install the ROM on this Mac: `tools/05_fetch_rom.sh --install`, or see [Installing ROMs](installing-roms.md) |
| Alert "The Apple II ROM file is N bytes" | The installed file isn't a 12,288-byte Apple II+ ROM. Replace it |
| The window opens but the screen is blank, or stops at `]` | Run the [boot check](#4-check-that-it-boots). The disk may need an Apple //e, a second disk, or a program started by hand |

## T2-hybrid: Number Munchers only

A second path, **T2-hybrid**, translates the game's 6502 code to C with [apple2tc](https://github.com/tmikov/apple2tc) and compiles it natively. A built-in 6502 interpreter runs anything that wasn't translated, and the result is checked frame by frame against the emulator.

These scripts are written for MECC's *Number Munchers* v1.3 (the 4am crack) and its title-screen and code addresses. **They don't work for other disks.** If you have that disk, the commands are in [Command-line tools](command-line-tools.md#t2-hybrid-recompiled-to-native-code). The T2-hybrid app needs no ROM. Its **Quit** restarts at the title screen instead of rebooting the disk.

## See also

- [Native conversion toolkit](native-conversion.md): the tiers and the Number Munchers results.
- [Command-line tools](command-line-tools.md): every script.
- [Signal flow: T1 and T2 build stages](signal-flow.md#t1-and-t2-build-stages): diagram of the stages.
- [Credits](credits.md): where the educational software comes from.
