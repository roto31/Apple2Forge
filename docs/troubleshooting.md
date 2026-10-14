# Troubleshooting

Logs are in `~/Library/Logs/Apple2Forge/`:

| Log | Written by |
|---|---|
| `emulator.log` | The game window (`a2emu`) |
| `library-download.log` | Downloading disk images |
| `library-catalog.log` | Building the catalog |
| `compat-sweep.log` | The compatibility check |

Messages from Apple2Forge appear in its main window.

## Starting the app

**"Apple2Forge can't be opened" / "cannot verify the developer"**
Apple2Forge 0.4.0 and later are notarized and shouldn't show this. Releases 0.3.0 and earlier, and T1/T2 apps built on another Mac, aren't notarized: use **System Settings ▸ Privacy & Security ▸ Open Anyway**. See [First launch](getting-started.md#first-launch).

## Starting a title

**"The Apple ][+ ROM is not installed (apple2plus.rom)…"** (or the Apple //e ROM)
Install the ROM files: see [Installing ROMs](installing-roms.md). //e titles need both `apple2e-enhanced.rom` and `apple2e-video.rom`.

**"… is not a startup disk. Its other disks are used from within another title."**
The disk has no boot sector, so it can't start anything by itself. It is a data or program disk used by another title in the same subject; start that title.

**"The disk image … is missing. Download the educational library again to restore it."**
A file was moved or deleted from the library's `disks/` folder. **Library ▸ Download Educational Library…** downloads only what is missing.

**"The bundled emulator is missing. Rebuild Apple2Forge.app"**
The app bundle is incomplete. Download the release again, or rebuild it: see [Building from source](building-from-source.md).

**"The emulator stopped (exit N)."**
`a2emu` ended with an error. The reason is at the end of `~/Library/Logs/Apple2Forge/emulator.log`, for example a ROM file of the wrong size.

**A title starts but shows a blank screen, garbage, or an error**
- Some images in the archive are damaged, or need hardware that isn't emulated (a mouse, a clock card, a printer).
- Titles that booted on neither machine during the compatibility check are still offered on the Apple ][+. They are listed in `compat.json` in the library folder, with the reason.
- If the compatibility check was skipped because the ROMs weren't installed yet, install them, then run **Library ▸ Download Educational Library…** again. It skips the files it already has, then rebuilds the catalog and runs the check.

**A title runs on the wrong machine**
You can force the machine for a title: add `"<title id>": {"requirement": "IIe128K"}` (or `"IIplus64K"`) to `library/subject_overrides.json` in a source checkout, then rebuild the catalog with `tools/50_library.sh`. The title id is listed in `library.json`.

## During play

**The arrow keys do nothing**
- Make sure the game window is selected.
- If joystick mode is on (F7), the arrows move the joystick instead of typing. Press F7 to turn it off.
- Some games use other keys, such as I/J/K/M or the space bar; check the game's own instructions.

**Lower-case letters don't work**
The Apple ][+ has no lower case, so letters are typed in upper case. Titles that use lower case run on the //e.

**The menu bar shows no Library or Disk menu**
The game window was probably brought forward through its Dock icon or the app switcher, which made the emulator the active app. Click the Apple2Forge main window, and the menus return.

**"The emulator did not accept the disk change"**
The game has already quit. Start the title again.

**The picture looks blurry, striped or fringed with colour**
That's the **Classic** display style. Choose **Smooth** under **Apple2Forge ▸ Settings… ▸ Display**, then start the title again. If the picture still looks wrong, press F3 until the window title shows `HGR:smooth`.

**The game says the disk is write-protected**
All disks are write-protected: see the [FAQ](faq.md#why-dont-my-scores-or-records-save).

## Library download

**"Downloading disk images failed (exit N)."**
Usually a network problem or a mirror outage. `library-download.log` has the details. Starting the download again resumes it.

**"That folder can't hold the library."**
The folder isn't writable, or is inside an app bundle. Choose another folder.

**A subject seems to be missing titles**
Titles are sorted by their file names. Those that match no subject rule are left out of the menu. Subjects can be assigned in `library/subject_overrides.json` in a source checkout.

## Build tab

**"The apple2-native project folder was not found. Choose it in Apple2Forge > Settings."**
The Build tab runs the toolkit's scripts from a checkout of this repository; the app doesn't contain them. Clone the repository, run its setup, then choose the folder in **Apple2Forge ▸ Settings… ▸ Project folder**. See [Apple2Forge: Set up once](apple2forge.md#set-up-once).

**"… does not contain the project's tools folder."** (Settings)
Choose the top folder of the checkout, the one containing `tools/00_setup.sh`.

**The setup check lists a missing item**
Each item names its fix:
- **ROM-free emulator:** `tools/15_build_a2emu_norom.sh`.
- **Apple II+ ROM for builds:** `tools/05_fetch_rom.sh`.
- **Apple II+ ROM for T1 apps:** `tools/05_fetch_rom.sh --install`.
- **A failed toolchain gate:** see [Building from source](#building-from-source) below.

Choose **Run Again** afterwards.

**Analyze passes but Wrap (T1) is SKIPPED, "Unsupported"**
The image isn't a 140K sector image. `.nib` images are recognised but not supported; convert to `.dsk` first. The reason is in **Report** and in `analysis.md`.

**Wrap (T1) FAILED**
Choose **Show Log**: the failing gate prints its repair step. The causes are the same as in [Make a Mac app from your disk: Troubleshooting](make-a-mac-app-from-your-disk.md#troubleshooting).

**There's no Try T2 button**
T2 is offered only for disks in `tools/t2/profiles.json`. It has one, the Number Munchers v1.3 4am crack. See [T2 for another disk](native-conversion.md#t2-for-another-disk).

**The exported app shows "Apple II ROM not found"**
T1 apps load your ROM from `~/Library/Application Support/Apple2Forge/roms/apple2plus.rom` on the Mac that runs them. Install it there: see [Installing ROMs](installing-roms.md).

## Building from source

Each build script prints which gate failed and why, and writes a log to `work/_logs/`. Common causes:

- `cmake` or `python3` missing: `brew install cmake python3`.
- `tools/15_build_a2emu_norom.sh` needs `roms/apple2plus.rom` in the checkout: run `tools/05_fetch_rom.sh` first.
- "*.patch no longer applies*": the apple2tc pin was moved with `tools/00_setup.sh --update`. Return to the pinned commit in `vendor/apple2tc.COMMIT`.
