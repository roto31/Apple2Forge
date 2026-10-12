# Architecture

The project has two parts: the [native conversion toolkit](native-conversion.md), which is the scripts in `tools/`, and [Apple2Forge](apple2forge.md), the bundled app.

```mermaid
flowchart LR
  subgraph Repo["Source checkout of this repository"]
    Tools["Native conversion toolkit<br/>tools/00–55 scripts, tools/lib/*.py,<br/>t2/ runtime, vendor/patches/"]
    Work[("work/#lt;disk#gt;/<br/>analysis, captures, C code, apps")]
  end
  subgraph Forge["Apple2Forge.app"]
    LibraryTab["Library tab + menus"]
    BuildTab["Build tab + Settings"]
    Bundled["Contents/Resources:<br/>a2emu, library scripts and rules"]
  end
  Disk[("Your disk image")]
  Asimov[("Asimov mirror")]
  Apps["T1 / T2-hybrid apps<br/>~/Library/Application Support/Apple2Forge/builds/"]

  LibraryTab --> Bundled
  Bundled -->|HTTPS| Asimov
  BuildTab -->|"runs scripts in place<br/>(project folder from Settings)"| Tools
  Disk --> BuildTab
  Disk -->|command line| Tools
  Tools --> Work
  BuildTab -->|copies results| Apps
```

The **Library** side is self-contained: its scripts are bundled inside the app. The **Build** side runs the toolkit's scripts in a checkout, because the toolchain (apple2tc, the emulator build) and each disk's working files live there.

Apple2Forge itself is two programs working together:

- **Apple2Forge.app**, a SwiftUI app. It owns the menus, the library, the build queue and settings, and starts games.
- **`a2emu`**, the Apple II emulator from [apple2tc](https://github.com/tmikov/apple2tc), patched by this project. It runs each game in its own window and process.

The library work itself (download, catalog, compatibility check) is done by shell and Python scripts bundled inside the app. The build work is done by the toolkit's scripts in the checkout. In both cases the Swift code only runs the scripts and shows their progress.

For step-by-step diagrams of each interaction, see [Signal flow](signal-flow.md).

## Components

```mermaid
flowchart TB
  subgraph App["Apple2Forge.app (SwiftUI, one process)"]
    direction TB
    Menus["Library and Disk menus<br/>(LibraryCommands, DiskCommands)"]
    Window["Main window<br/>(LibraryWindow: status, download progress, errors)"]
    Model["LibraryModel<br/>(loads library.json)"]
    Session["EmulatorSession<br/>(runs one a2emu, sends disk commands)"]
    Download["DownloadController + DownloadPipeline<br/>(runs the scripts, parses progress)"]
    Settings["AppSettings + LibraryLocationStore<br/>(library folder bookmark, ROM and log folders)"]
    Core["Apple2ForgeCore<br/>(EmulatorLaunch, LibraryCatalog, ToolPaths, DriveCommand)"]
  end
  subgraph Resources["Apple2Forge.app/Contents/Resources"]
    Emu["a2emu (patched emulator)"]
    Scripts["tools/07_fetch_edu_library.sh<br/>tools/50_library.sh<br/>tools/55_compat_sweep.sh<br/>tools/lib/*.py"]
    Rules["library/*.json<br/>(subject and grouping rules)"]
  end
  subgraph Disk["Your Mac"]
    Roms[("~/Library/Application Support/Apple2Forge/roms/<br/>(you install)")]
    Lib[("Library folder<br/>disks/, manifest.json, library.json, compat.json")]
    Logs[("~/Library/Logs/Apple2Forge/")]
    Links[("~/Library/Caches/Apple2Forge/launch/")]
  end
  Mirror[("Asimov mirror<br/>mirrors.apple2.org.za")]
  GameWin["Game window<br/>(a2emu process, non-activating panel)"]

  Menus --> Session
  Menus --> Download
  Window --> Download
  Model --> Menus
  Session --> Core
  Download --> Core
  Settings --> Session
  Settings --> Download
  Download -->|bash| Scripts
  Scripts --> Rules
  Scripts -->|HTTPS| Mirror
  Scripts --> Lib
  Scripts -->|headless boots| Emu
  Model --> Lib
  Session -->|"symlink named after the title"| Links
  Links --> Emu
  Emu --> GameWin
  Emu -->|reads| Roms
  Emu -->|reads| Lib
  Session -->|"stdin pipe: mount / eject"| Emu
  Emu -->|stdout, stderr| Logs
  Download --> Logs
```

### Build tab components

```mermaid
flowchart TB
  subgraph UI["Apple2Forge (UI target)"]
    BW["BuildWindow<br/>(drop zone, cards, report, actions)"]
    BQ["BuildQueue<br/>(one build at a time, recordings, export)"]
    SM["SetupModel<br/>(first-run setup check)"]
    SV["SettingsView<br/>(project folder, ROM, builds folder)"]
  end
  subgraph Core["Apple2ForgeCore"]
    BP["BuildPipeline<br/>(stages, outputs, previous-#lt;time#gt;/)"]
    PT["ProjectTools<br/>(finds and checks the project folder)"]
    SR["ScriptRunner<br/>(Process, log file, cancel with children)"]
    PR["BuildProfile<br/>(tools/t2/profiles.json, matched by SHA-256)"]
    CR["CompatibilityReport<br/>(tier, reasons, T2 verdict, next steps)"]
    SC["SetupCheck<br/>(parses 00_setup.sh gates, file checks)"]
  end
  Proj[("Project folder:<br/>tools/*.sh, work/")]
  Builds[("~/Library/Application Support/<br/>Apple2Forge/builds/#lt;disk#gt;/")]

  BW --> BQ
  BQ --> BP
  BQ -->|Record / Replay| SR
  SM --> SC
  SM --> SR
  SV --> PT
  BP --> PT
  BP --> SR
  BP --> PR
  BP --> CR
  SR -->|bash| Proj
  BP --> Builds
```

`ProjectTools.locate` picks the project folder in this order:
1. the folder chosen in Settings, or `--project=`
2. the folder recorded in `Info.plist` by a development build
3. any folder above the app's executable that contains the toolkit

A release build records none, so a downloaded app finds a project only through Settings.

## Processes

| Process | Started by | Lifetime | Talks to |
|---|---|---|---|
| Apple2Forge | You | Until you quit | Starts the others |
| `a2emu` (game) | Library menu | Until its window closes, or another title starts | Reads disk commands on standard input; writes `emulator.log` |
| `bash` + `python3` (library scripts) | Download / Rebuild Catalog | One step at a time | Writes JSON progress on standard output, log text on standard error |
| `a2emu --headless` | The compatibility check | About 30 s to 2 min per title | Writes a machine snapshot that the check judges |
| `bash` (toolkit stage scripts) | Build tab | One stage at a time; about 9 minutes for a full T2 build | Writes a log per stage to `builds/<disk>/logs/`. **Cancel** stops it and its children |
| `a2emu` (recorder) | Record Coverage… | Until you close its window | `tools/45_record.sh` collects keys and executed code |

Only one game runs at a time. Starting a title stops the running one first.

## Why the game runs in its own process

- **Isolation**: a game that crashes the emulator doesn't take the app with it. Apple2Forge reports the exit code and keeps running.
- **Upstream code unchanged where possible**: `a2emu` is apple2tc's own front end, built on sokol, so this project's changes stay small patches (see [Building from source](building-from-source.md#3-tools15_build_a2emu_noromsh)).
- **Window title**: `a2emu` titles its window with the name it was started as. Apple2Forge therefore starts it through a symlink named after the title, in `~/Library/Caches/Apple2Forge/launch/`.

## Keeping the menu bar

On macOS the menu bar belongs to the active app. A normal window from a second process would make that process active, and `a2emu` has no menus. The game window is therefore a *non-activating panel*: it receives the keyboard, but Apple2Forge stays the active app, so the **Library** and **Disk** menus remain. See [Signal flow: focus and the menu bar](signal-flow.md#focus-and-the-menu-bar).

## Emulated machines

| | Apple ][+ | Enhanced Apple //e |
|---|---|---|
| CPU | 6502 | 65C02 |
| Memory | 48K + 16K Language Card | 128K (main + auxiliary) |
| ROM file | `apple2plus.rom` (12K) | `apple2e-enhanced.rom` (16K) + `apple2e-video.rom` |
| Text | 40 columns, upper case | 40/80 columns, lower case, MouseText |
| Extra keys | — | Open Apple, Solid Apple |
| `a2emu` options | `--rom=…` | `--model=iie --rom=… --video-rom=…` |

Both have a Disk II controller in slot 6 with two drives.

## Source layout

| Path | Contents |
|---|---|
| `app/Apple2Forge/` | Swift package: `Apple2Forge` (UI) and `Apple2ForgeCore` (testable logic), with unit tests |
| `tools/` | Numbered scripts for each stage, plus `tools/lib/` Python modules and `tools/t2/profiles.json` |
| `library/` | Subject, grouping and override rules for the catalog |
| `vendor/patches/` | Patches applied to apple2tc; `vendor/apple2tc.COMMIT` pins the upstream commit |
| `t2/` | Runtime for recompiled (T2-hybrid) apps |
| `tests/` | Gate scripts per stage, Python unit tests, scripted play sessions |
| `docs/` | This documentation |

Folders created by the scripts, all ignored by Git: `vendor/apple2tc/` (upstream clone), `vendor/apple2tc-norom-src/` (patched export), `build/`, `work/`, `roms/`.

## Design rules

- **No ROMs or disk images in the repository, and no system ROM in the app.** The build checks every byte of the emulator and the app bundle for system-ROM content. The Disk II boot PROM and the Apple ][ text font compiled in from upstream are the known exceptions ([notices](../THIRD_PARTY_NOTICES.md#apple-firmware)).
- **Nothing written inside the app bundle.** The library, ROMs, logs, launch links and builds live in your Library folder.
- **One source of truth for library and build logic**: the scripts. The app only runs them; none of the stage logic is rewritten in Swift.
- **Every script stops at the first failed check** and prints a summary, so a half-finished step never looks like success.
