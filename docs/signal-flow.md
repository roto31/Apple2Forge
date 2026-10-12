# Signal flow

These diagrams follow each interaction from the click or key press to the emulated Apple II, using the names in the source code. For the overall structure, see [Architecture](architecture.md).

## Starting a title

```mermaid
sequenceDiagram
  actor User
  participant Menu as Library menu
  participant Session as EmulatorSession
  participant Launch as EmulatorLaunch
  participant FS as Your Mac (ROMs, library, caches)
  participant Emu as a2emu process

  User->>Menu: choose Subject ▸ Title
  Menu->>Session: launch(title)
  Session->>Session: ToolPaths.locate(): find a2emu in Contents/Resources
  Session->>Launch: build arguments for the title
  Launch->>FS: ROM files for the machine present?
  alt ROM missing
    Launch-->>Session: missingRoms
    Session-->>User: error shown in the main window
  end
  Launch->>FS: disk images for drive 1 (and 2) present?
  Launch-->>Session: --control-fd=0, --rom=… [--model=iie --video-rom=…], --disk1=… [--disk2=…]
  Session->>Session: stop() any running game
  Session->>FS: symlink launch/<Title> → a2emu
  Session->>Emu: start via the symlink<br/>stdin = control pipe, stdout/stderr = emulator.log
  Emu->>FS: load ROM, mount disks
  Emu->>Emu: power on: ROM reset → slot 6 Disk II boot → DOS/ProDOS → game
  Emu-->>User: game window titled <Title>
  Note over Session,Emu: When a2emu exits, terminationHandler clears the session<br/>and a non-zero exit is reported in the main window
```

## Keyboard input

A key press goes from macOS to the emulator's window, through a chain of handlers, to the Apple II keyboard latch at `$C000`.

```mermaid
flowchart TD
  K[Key press on the Mac] --> WS[macOS delivers it to the key window:<br/>the game panel]
  WS --> SK[sokol: KEY_DOWN event,<br/>plus a CHAR event for typed characters]
  SK --> H1{F3–F6?}
  H1 -->|yes| D[Display: hi-res mode, phosphor persistence] --> X1((consumed))
  H1 -->|no| RG{Recorded key replay active?}
  RG -->|yes| X2((ignored))
  RG -->|no| J{F7, or joystick mode on<br/>and an arrow, Space, Left Option, Left Control?}
  J -->|yes| JS[Toggle joystick mode, or move stick / press button<br/>→ paddle and button inputs $C061–$C067] --> X3((consumed))
  J -->|no| OA{//e and Option?}
  OA -->|yes| PB[Open Apple / Solid Apple → pushbutton 0 / 1] --> X4((consumed))
  OA -->|no| T{Event type}
  T -->|CHAR| C1[II+: letters to upper case, Delete → $08<br/>//e: unchanged]
  T -->|KEY_DOWN| C2[Special keys:<br/>← $08 · → $15 · ↑ $0B · ↓ $0A<br/>Return $0D · Esc $1B · Delete $08 II+ / $7F //e]
  C1 --> P[a2host_press_key]
  C2 --> P
  P --> L[Keyboard latch $C000, bit 7 set]
  L --> G[Game reads $C000, then clears the strobe at $C010]
```

The special keys mark their character as already sent, so the CHAR event that follows the same key press doesn't type it twice.

## Disk swap

```mermaid
sequenceDiagram
  actor User
  participant Menu as Disk menu
  participant Session as EmulatorSession
  participant Pipe as stdin pipe
  participant Emu as a2emu
  participant Drive as Disk II drive

  User->>Menu: Insert into Drive 2 ▸ Disk 1 Side B
  Menu->>Session: insert(side, drive: 2)
  Session->>Session: DriveCommand.mount builds the line mount 2 PATH<br/>(drive must be 1 or 2, and the path must not contain a newline)
  Session->>Pipe: write line
  alt a2emu has exited
    Pipe-->>Session: write fails
    Session-->>User: "The emulator did not accept the disk change"
  end
  Note over Emu: At the start of every frame, read the pipe without blocking,<br/>so a change never lands mid-instruction
  Emu->>Drive: mount the image in drive 2
  Session->>Session: driveContents[2] = side
  Drive-->>Emu: the game's next read gets the new disk
```

**Eject** works the same way, with `eject D`.

## Focus and the menu bar

```mermaid
sequenceDiagram
  actor User
  participant WS as macOS
  participant Forge as Apple2Forge (active app)
  participant Panel as Game panel (a2emu)

  Note over Panel: Created as an NSPanel with the non-activating style.<br/>Shown with orderFrontRegardless + makeKeyWindow,<br/>without activating the a2emu process
  User->>WS: click in the game window
  WS->>Panel: becomes the key window
  Note over Forge: Stays the active app,<br/>so the menu bar keeps Library and Disk
  User->>WS: type
  WS->>Panel: key events → see "Keyboard input"
  User->>WS: open the Disk menu
  WS->>Forge: menu tracking and command
  Forge->>Panel: disk command over the pipe → see "Disk swap"
```

If the game window is brought forward some other way, such as its Dock icon or the app switcher, the `a2emu` process can become the active app. The menu bar then has no Apple2Forge menus until you click the Apple2Forge window.

## Library download, catalog and compatibility check

```mermaid
flowchart TD
  M[Library ▸ Download Educational Library…] --> A{Location chosen before?}
  A -->|no| AL[Alert: Use Default Location / Choose Location…]
  AL --> V[LibraryLocation.validate:<br/>writable, not inside an .app]
  A -->|yes| V
  V --> BM[Remember the folder as a bookmark]
  BM --> P[DownloadPipeline.run]
  P --> S1["Step 1: bash tools/07_fetch_edu_library.sh --dest=DIR --progress=json"]
  S1 --> F[edu_fetch.py: list the mirror's educational folder,<br/>keep .dsk without '4am', download the missing ones]
  F -->|HTTPS| MIR[(mirrors.apple2.org.za)]
  F --> O1[(DIR/disks/, DIR/manifest.json)]
  S1 -->|one JSON object per line on stdout| PR[Progress bar: files, bytes, time left]
  S1 --> S2["Step 2: tools/50_library.sh --library=DIR"]
  S2 --> C[library_catalog.py: group sides/disks into titles,<br/>subjects from library/*.json rules]
  C --> O2[(DIR/library.json)]
  S2 --> R{All three ROM files installed?}
  R -->|no| SK[Skip the check: machine from the file name]
  R -->|yes| S3["Step 3: tools/55_compat_sweep.sh"]
  S3 --> B[For each title: a2emu --headless on the II+,<br/>then the //e if needed; judge the screen and registers]
  B --> O3[(DIR/compat.json)]
  S3 --> S4[Rebuild library.json with the results]
  SK --> RL[LibraryModel.reload]
  S4 --> RL
  RL --> LM[Library menu: Subject ▸ Title, with machine labels]
```

## Compatibility check: one title

```mermaid
flowchart TD
  T[Title: drive 1 and 2 images] --> P["Boot on the Apple ][+ for 30 s, headless"]
  P --> PB{Booted, and the name<br/>doesn't mention the //e?}
  PB -->|yes| R1["Apple ][+"]
  PB -->|no| E[Boot on the Apple //e]
  E --> EB{//e booted?}
  EB -->|yes| R2["Apple //e"]
  EB -->|no| PB2{II+ booted?}
  PB2 -->|yes| R1
  PB2 -->|no| NB{No boot sector on either?}
  NB -->|yes| R3[Not a startup disk: greyed out]
  NB -->|no| R4[Unknown: offered on the II+]
```

A boot counts as failed if the screen is blank, shows an error or a bare prompt, or the CPU hit an invalid instruction. Blank screens are retried for up to 2 minutes, for slow loaders.

## T1 and T2 build stages

These [command-line tools](command-line-tools.md) turn a disk image you own into a standalone app.

```mermaid
flowchart LR
  DSK[(Your .dsk)] --> AN["10_analyze.sh<br/>analysis.json"]
  AN --> T1["20_wrap_t1.sh<br/>T1 app: a2emu + disk,<br/>ROM loaded at launch"]
  DSK --> CAP["30_capture.sh<br/>snapshots at known points,<br/>executed code"]
  CAP --> COV["40_coverage.sh<br/>replay scripted sessions,<br/>coverage.json"]
  COV --> REC["50_recompile.sh<br/>apple2tc → C → native,<br/>frame-hash comparison with a2emu"]
  REC --> T2["55_wrap_t2.sh<br/>T2-hybrid app:<br/>native code + 6502 interpreter fallback"]
```

Each stage writes to `work/<disk>/` and has a matching gate script in `tests/`.
