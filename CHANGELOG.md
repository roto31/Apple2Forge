# Changelog

All notable changes to this project (the native conversion toolkit and the bundled Apple2Forge app) are listed here. Version numbers are Apple2Forge's. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Documentation

- [Docs index](docs/README.md)
- [Wiki home](https://github.com/roto31/Apple2Forge/wiki)

## [Unreleased]

## [0.2.0] - 2026-10-11

The repository now holds the whole project: the [native conversion toolkit](docs/native-conversion.md), and [Apple2Forge](docs/apple2forge.md), documented as the app bundled with it. The public history was squashed into one commit; the v0.1.0 tag still points at the first release.

### Added
- **Build tab** in Apple2Forge. Drop `.dsk`, `.do`, `.po` or `.nib` images on it, or on the app icon, and each disk runs through Analyze → Wrap (T1) → Package, one disk at a time. Each stage shows PASS, FAIL or SKIPPED with its log.
  - A compatibility report gives the tier reached, the reasons it isn't higher, whether T2 is possible, and next steps.
  - **Export T1 App…** copies the built app.
  - **Try T2** runs Capture → Coverage → Recompile (T2) for profiled disks (Number Munchers v1.3 4am crack, about 9 minutes).
  - **Cancel** stops a build and its child processes.
  - It needs a source checkout of this repository, chosen in Settings. See [Apple2Forge: Build tab](docs/apple2forge.md#build-tab).
- **Record Coverage…** and **Replay** (`tools/45_record.sh`): play a disk in a window and save the keys and the code that ran, then check that a replay runs exactly the same code. See [Command-line tools](docs/command-line-tools.md#recording-your-own-play-session).
- **Settings** (project folder, ROM files, builds folder, apple2tc commit) and a first-run **setup check** that runs `tools/00_setup.sh` and lists each gate and missing file with its fix.
- Command-line modes `--build=DISK [--t2]`, `--project=DIR`, `--builds-dir=DIR`, `--drop=PATH` and `--quit-after-build=S`. See [Command-line tools](docs/command-line-tools.md#apple2forge-command-line-modes).
- `tools/t2/profiles.json`: the disks T2 is attempted for, matched by SHA-256.
- `tools/60_build_app.sh --release`: distribution build with no project path recorded and debug symbols stripped. It fails if a local path is found in the bundle.
- `tools/25_check_t1.sh APP.app`: boots a T1 app's own emulator and disk without a window on the Apple ][+ and reports whether the disk starts. It uses the same rules as the library's compatibility check (exit 0 boots, 1 does not, 2 can't check). Measured results for 11 disks are in [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md#results-so-far).
- `tests/stage6_build_gate.sh`: the Build tab's gate, B1–B11.

### Changed
- Apple2Forge opens on the **Build** tab. The Library tab and **Library** menu work as before.
- Docs reorganised around the two parts of the project:
  - New: [Native conversion toolkit](docs/native-conversion.md), with the Number Munchers case study and its measured results, and [Apple2Forge](docs/apple2forge.md).
  - New sections: the Build tab in [Architecture](docs/architecture.md), [Signal flow](docs/signal-flow.md#build-tab) and [Troubleshooting](docs/troubleshooting.md#build-tab), and [Using the Build tab instead](docs/make-a-mac-app-from-your-disk.md#using-the-build-tab-instead).
  - New wiki pages: Native Conversion Toolkit and Apple2Forge App.
- Screenshots of the app's UI in the README, [Apple2Forge](docs/apple2forge.md), [Getting started](docs/getting-started.md), [Educational library](docs/library.md), [Disk swapping](docs/disk-swapping.md) and [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md), and the same pages in the wiki. They cover:
  - the Build tab setup check and build reports
  - Settings
  - the Library tab, Library menu, download location alert and download progress
  - the Disk menu

  They show the app only, no game screens.

### Fixed
- Settings listed the ROM-free emulator under **Apple II ROM** as a "12288 bytes" ROM file. The section now shows only the two Apple II+ ROM files.

### Security
- The 0.1.0 app's binary contained the build Mac's source-folder path (a user name and folder names; no credentials) in its debug symbols. 0.2.0 is built with `--release`, which strips them and checks for local paths.

### Docs
- New guide: [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md). It covers requirements, step-by-step commands, what each gate checks, the boot check, limits (Apple ][+ only, one disk, read-only, ROM needed on every Mac), troubleshooting, and the Number Munchers-only T2 path.
- New page: [Credits](docs/credits.md). It credits the Asimov Apple II archive, the folder the library downloads from (<https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/>) on the APPLE2.ORG.ZA mirror, the original publishers (MECC, Scholastic, Sunburst and others), and the software Apple2Forge builds on. It's linked from the README, library, legal and notices pages, and the wiki footer.
- Corrected the description of the disk-to-app tools. They are not "standalone": a T1 app needs your own Apple II+ ROM installed on the Mac that runs it. T1 emulates the Apple ][+ only and has been tested end to end with Number Munchers only. T2 works for Number Munchers v1.3 only. See [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md).
- Corrected the system requirements. The release is arm64 (Apple silicon) only, not "Apple silicon or Intel".

### Known issues
- The Build tab needs a source checkout of this repository. A downloaded app alone reports "project folder not found" there; the Library tab is unaffected.
- The in-window mouse drag wasn't automated in testing. The gate sends the same open-file event as a drop on the app icon.
- Disks are still write-protected, and the bundled emulator still contains the Disk II boot PROM and the text font ([notices](THIRD_PARTY_NOTICES.md#apple-firmware)).

## [0.1.0] - 2026-10-11

First public release.

### Added
- **Library menu** with about 1,200 educational titles in ten subjects: Math, History, Social Studies, Science, Geography, Health, Arts, Writing, Literature and Reading. See [Educational library](docs/library.md).
- **Library ▸ Download Educational Library…** downloads about 2,300 disk images (about 330 MB), builds the catalog, and test-boots every title to find the machine it needs. You can pick the default folder or your own, and Apple2Forge remembers the choice. Starting a stopped download again resumes it.
- **Library ▸ Change Library Location…**, **Show Library in Finder** and **Rebuild Catalog**.
- Multi-disk titles start with all disks in place (side A in drive 1, side B in drive 2). The **Disk** menu inserts and ejects sides while the game runs. See [Disk swapping](docs/disk-swapping.md).
- Enhanced Apple //e emulation (128K, 65C02, 80 columns) for titles that need it. Other titles run on an Apple ][+ with a 16K Language Card.
- Display keys F3–F6 (hi-res colour modes, phosphor persistence) and a joystick mode on F7. See [Playing games](docs/playing-games.md).
- Command-line modes: `--dump-menu`, `--print-library`, `--set-library=DIR`, `--download-to=DIR`, `--print-launch=ID`. See [Command-line tools](docs/command-line-tools.md#apple2forge-command-line-modes).
- Developer tools that wrap an Apple ][+ disk image you own into a Mac app (T1, emulator wrap; needs your own ROM installed to run; tested end to end with Number Munchers), and a recompiled "T2-hybrid" build for Number Munchers v1.3 only. See [Command-line tools](docs/command-line-tools.md).

### Fixed
- Up and Down arrows work on the Apple ][+ as well as the //e. They send Ctrl-K and Ctrl-J, which II+ games such as Number Munchers read as up and down.
- The Library and Disk menus stay usable while a game window is selected.
- Disk images saved in ProDOS sector order boot correctly instead of scrambled.
- 65C02 decimal-mode `ADC`/`SBC` set the N and Z flags correctly, so ProDOS 8 2.x starts on the //e.

### Known issues
- Disks are write-protected: progress, scores and student records are not saved. See [FAQ](docs/faq.md).
- Some titles don't boot on either machine. Those with no boot sector are greyed out; the others are still offered on the Apple ][+. See [Troubleshooting](docs/troubleshooting.md).
- If the game window is brought forward through its Dock icon or the app switcher, the menu bar may show no menus. Click the Apple2Forge window to get them back.
- The bundled emulator contains Apple's 256-byte Disk II boot PROM and a 2 KB Apple ][ text font adapted from the character-generator ROM, both from upstream apple2tc. See [third-party notices](THIRD_PARTY_NOTICES.md#apple-firmware).
- The app is ad-hoc signed, not notarized: see [first launch](docs/getting-started.md#first-launch).

[Unreleased]: https://github.com/roto31/Apple2Forge/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/roto31/Apple2Forge/releases/tag/v0.2.0
[0.1.0]: https://github.com/roto31/Apple2Forge/releases/tag/v0.1.0
