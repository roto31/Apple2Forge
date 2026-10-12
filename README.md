# apple2-native: Apple II disks to native Mac apps

This repository turns Apple II disk images into Mac apps. It has two parts:

| Part | What it is | Needs |
|---|---|---|
| **[Native conversion toolkit](docs/native-conversion.md)** | Scripts in `tools/` that analyze a 140K disk image you own and wrap it into a Mac app. In a **T1** app, the original program runs in a built-in emulator. For MECC's *Number Munchers* v1.3, they also recompile the game's 6502 code to native arm64 (**T2-hybrid**) | A source checkout, the Xcode Command Line Tools, `cmake`, `python3`, and your own Apple II+ ROM |
| **[Apple2Forge](docs/apple2forge.md)** (bundled app) | A Mac app with two tabs. **Library** downloads and plays about 1,200 Apple II educational titles. **Build** runs the toolkit on disk images you drag in | Library: the [release download](https://github.com/roto31/Apple2Forge/releases) and your ROMs. Build: a source checkout as well |

> **No Apple system ROMs or games are included.** Disk images are downloaded only when you ask, and you install the Apple II ROMs yourself. The bundled emulator does contain two small pieces of Apple-derived firmware data from upstream apple2tc: the Disk II boot PROM and the Apple ][ text font. See [third-party notices](THIRD_PARTY_NOTICES.md#apple-firmware). Use only software and ROMs you are entitled to use; apps built from your disks are for personal use. See [Legal and ROMs](docs/legal-and-roms.md).

## Native conversion toolkit

| Tier | What runs | Works for |
|---|---|---|
| **T1** | The original program, unchanged, in the patched `a2emu` emulator (Apple ][+, 64K) inside the app. The app loads your Apple II+ ROM at launch | Any 140K `.dsk`, `.do` or `.po` the analyzer supports. Tested end to end with Number Munchers; [boot-checked on 11 disks](docs/make-a-mac-app-from-your-disk.md#results-so-far), 9 of which start |
| **T2-hybrid** | The game's 6502 code translated to C by [apple2tc](https://github.com/tmikov/apple2tc) and compiled natively, with a 6502 interpreter for anything not translated. No ROM needed | Number Munchers v1.3 (4am crack) only |

For Number Munchers, the T2-hybrid build matched the emulator frame for frame on 17 of 17 recorded play sessions (153,202 frames) and on 16 of 16 random-key sessions (472,305 frames). In those sessions, 99% or more of the instructions ran as native code. Stages, results and limits: [Native conversion toolkit](docs/native-conversion.md). Step by step for your own disk: [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md).

## Apple2Forge

Apple2Forge is a separate, self-contained app bundled with the project:

- **Library tab:** about 1,200 educational titles from the [Asimov Apple II archive](docs/credits.md#educational-software), downloaded from its [educational folder](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/) on the APPLE2.ORG.ZA mirror. They're sorted into Math, History, Social Studies, Science, Geography, Health, Arts, Writing, Literature and Reading.
  - Each title is test-booted after download, so it starts on the machine it needs: an Apple ][+, or an enhanced Apple //e for 128K titles.
  - Multi-disk titles start with side A in drive 1 and side B in drive 2, and the **Disk** menu swaps sides while the game runs.
- **Build tab:** drop `.dsk`, `.do`, `.po` or `.nib` images to analyze them and build T1 apps. **Try T2** is offered for profiled disks, and **Record Coverage** saves your own play sessions.
  - Each disk gets a compatibility report that says which tier it reached and why not higher.
  - The tab runs the toolkit's scripts in a source checkout of this repository, which you choose in **Settings**. The download alone doesn't include them.

See [Apple2Forge](docs/apple2forge.md).

| Library | Build |
|---|---|
| ![The Library menu with the Math submenu open](docs/images/library-menu.png) | ![Build tab cards with compatibility reports](docs/images/build-tab-reports.png) |

## Quick start

### Play the educational library

1. Download `Apple2Forge-<version>-macOS.zip` from [Releases](https://github.com/roto31/Apple2Forge/releases), unzip it and move `Apple2Forge.app` to Applications. The first launch needs one extra step, because the app is not notarized: see [Getting started](docs/getting-started.md#first-launch).
2. Install the Apple II ROMs: see [Installing ROMs](docs/installing-roms.md).
3. Choose **Library ▸ Download Educational Library…**, then **Use Default Location** or **Choose Location…**.
4. Choose a title from the **Library** menu.

### Turn your own disk into a Mac app

```bash
git clone https://github.com/roto31/Apple2Forge.git && cd Apple2Forge
tools/00_setup.sh && tools/05_fetch_rom.sh --install && tools/15_build_a2emu_norom.sh
tools/20_wrap_t1.sh "My Disk.dsk" --name "My Game"     # → work/my-disk/t1/My Game.app
tools/25_check_t1.sh "work/my-disk/t1/My Game.app"     # does the disk boot?
```

Or build the app with `tools/60_build_app.sh` and drop the disk on its **Build** tab. Details: [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md).

## Documentation

| Guide | What it covers |
|---|---|
| [Native conversion toolkit](docs/native-conversion.md) | Tiers, stages, the Number Munchers case study and its measured results, limits |
| [Apple2Forge](docs/apple2forge.md) | The bundled app: Library and Build tabs, Settings, what needs a source checkout |
| [Getting started](docs/getting-started.md) | Requirements, installing the app, first launch |
| [Installing ROMs](docs/installing-roms.md) | Which ROM files are needed and where they go |
| [Educational library](docs/library.md) | Downloading, choosing a location, subjects, the catalog |
| [Playing games](docs/playing-games.md) | Keyboard map, joystick mode, display keys, menus during play |
| [Disk swapping](docs/disk-swapping.md) | Multi-disk titles and the Disk menu |
| [Make a Mac app from your disk](docs/make-a-mac-app-from-your-disk.md) | Wrapping an Apple ][+ disk you own into a Mac app: steps, boot check, limits, results |
| [Building from source](docs/building-from-source.md) | Toolchain, emulator build, app build |
| [Command-line tools](docs/command-line-tools.md) | Every script, and the app's command-line modes |
| [Architecture](docs/architecture.md) | Components, processes, files and folders |
| [Signal flow](docs/signal-flow.md) | Diagrams of launch, keyboard, disk swap, focus, the Build tab and the pipelines |
| [Troubleshooting](docs/troubleshooting.md) | Error messages and what to do |
| [FAQ](docs/faq.md) | Common questions |
| [Credits](docs/credits.md) | The Asimov archive and mirror the games come from, their publishers, and the software this project builds on |

The same guides are in the [wiki](https://github.com/roto31/Apple2Forge/wiki). Changes are listed in the [changelog](CHANGELOG.md).

## Licence

This project is MIT-licensed: see [LICENSE](LICENSE). It builds on [apple2tc](https://github.com/tmikov/apple2tc) (MIT) and sokol (zlib); see [third-party notices](THIRD_PARTY_NOTICES.md). Apple, Apple II and Apple //e are trademarks of Apple Inc. This project is not affiliated with Apple.
