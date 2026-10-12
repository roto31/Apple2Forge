# Apple2Forge

Apple2Forge is a macOS app that plays Apple II educational software without any emulator setup. Pick a title from the **Library** menu and it starts on the right machine, an Apple ][+ or an enhanced Apple //e, with all of its disks already in the drives.

- About 1,200 educational titles, sorted into Math, History, Social Studies, Science, Geography, Health, Arts, Writing, Literature and Reading.
- Multi-disk titles start with side A in drive 1 and side B in drive 2. The **Disk** menu swaps sides while the game runs.
- Each title is test-booted after download, so it starts on the machine it needs. Titles that need 128K run on an emulated Apple //e.
- Includes command-line tools that turn a disk image you own into a standalone Mac app.

> **No Apple system ROMs or games are included.** Apple2Forge downloads disk images only when you ask it to, and you install the Apple II ROMs yourself. The bundled emulator does contain two small pieces of Apple-derived firmware data from upstream apple2tc: the Disk II boot PROM and the Apple ][ text font. See [third-party notices](THIRD_PARTY_NOTICES.md#apple-firmware). Use only software and ROMs you are entitled to use. See [Legal and ROMs](docs/legal-and-roms.md).

## Quick start

1. Download `Apple2Forge-<version>-macOS.zip` from [Releases](https://github.com/roto31/Apple2Forge/releases), unzip it and move `Apple2Forge.app` to Applications. The first launch needs one extra step, because the app is not notarized: see [Getting started](docs/getting-started.md#first-launch).
2. Install the Apple II ROMs: see [Installing ROMs](docs/installing-roms.md).
3. Choose **Library ▸ Download Educational Library…**, then **Use Default Location** or **Choose Location…**.
4. Choose a title from the **Library** menu.

## Documentation

| Guide | What it covers |
|---|---|
| [Getting started](docs/getting-started.md) | Requirements, installing the app, first launch |
| [Installing ROMs](docs/installing-roms.md) | Which ROM files are needed and where they go |
| [Educational library](docs/library.md) | Downloading, choosing a location, subjects, the catalog |
| [Playing games](docs/playing-games.md) | Keyboard map, joystick mode, display keys, menus during play |
| [Disk swapping](docs/disk-swapping.md) | Multi-disk titles and the Disk menu |
| [Building from source](docs/building-from-source.md) | Toolchain, emulator build, app build |
| [Command-line tools](docs/command-line-tools.md) | Every script, plus turning your own disk into a Mac app |
| [Architecture](docs/architecture.md) | Components, processes, files and folders |
| [Signal flow](docs/signal-flow.md) | Diagrams of launch, keyboard, disk swap, focus and pipelines |
| [Troubleshooting](docs/troubleshooting.md) | Error messages and what to do |
| [FAQ](docs/faq.md) | Common questions |

The same guides are in the [wiki](https://github.com/roto31/Apple2Forge/wiki). Changes are listed in the [changelog](CHANGELOG.md).

## Licence

Apple2Forge is MIT-licensed: see [LICENSE](LICENSE). It builds on [apple2tc](https://github.com/tmikov/apple2tc) (MIT) and sokol (zlib); see [third-party notices](THIRD_PARTY_NOTICES.md). Apple, Apple II and Apple //e are trademarks of Apple Inc. This project is not affiliated with Apple.
