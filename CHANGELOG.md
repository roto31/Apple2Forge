# Changelog

All notable changes to Apple2Forge are listed here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Documentation

- [Docs index](docs/README.md)
- [Wiki home](https://github.com/roto31/Apple2Forge/wiki)

## [Unreleased]

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
- Developer tools that turn a disk image you own into a standalone Mac app: an emulator wrap (T1), and a recompiled "T2-hybrid" build for Number Munchers. See [Command-line tools](docs/command-line-tools.md).

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

[Unreleased]: https://github.com/roto31/Apple2Forge/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/roto31/Apple2Forge/releases/tag/v0.1.0
