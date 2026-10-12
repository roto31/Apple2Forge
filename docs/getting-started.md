# Getting started

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel.
- **Python 3** for the library download, catalog and compatibility check, which Apple2Forge runs as scripts. Python 3 comes with the Xcode Command Line Tools: run `xcode-select --install` in Terminal if `python3 --version` reports that it is missing.
- About 330 MB of free space for the educational library.
- The Apple II ROM files: see [Installing ROMs](installing-roms.md).

## Install

1. Download `Apple2Forge-<version>-macOS.zip` from [Releases](https://github.com/roto31/Apple2Forge/releases).
2. Optionally, check the download against the `.sha256` file published with it:

   ```bash
   shasum -a 256 ~/Downloads/Apple2Forge-*-macOS.zip
   ```

3. Unzip it and move `Apple2Forge.app` to your Applications folder.

## First launch

The app is ad-hoc signed and not notarized by Apple, so macOS blocks the first launch:

1. Open `Apple2Forge.app`. macOS says it can't verify the developer; choose **Done**.
2. Open **System Settings ▸ Privacy & Security**, scroll to the message about Apple2Forge, and choose **Open Anyway**.
3. Open the app again and confirm.

After that it opens normally.

## First steps

1. **Install the ROMs**: see [Installing ROMs](installing-roms.md). Without them, titles can't start, and the post-download check that picks each title's machine is skipped.
2. **Download the library**: choose **Library ▸ Download Educational Library…**, then pick **Use Default Location** (`~/Library/Application Support/Apple2Forge/library/`) or **Choose Location…**. The main window shows progress; see [Educational library](library.md).
3. **Play**: choose a subject in the **Library** menu, then a title. The game opens in its own window. See [Playing games](playing-games.md).

## Where Apple2Forge keeps things

| What | Where |
|---|---|
| ROMs (you install them) | `~/Library/Application Support/Apple2Forge/roms/` |
| Educational library (default) | `~/Library/Application Support/Apple2Forge/library/` |
| Logs | `~/Library/Logs/Apple2Forge/` (`emulator.log` for the game window) |
| Launch links (window titles) | `~/Library/Caches/Apple2Forge/launch/` |

Nothing is written inside `Apple2Forge.app`.

## Uninstall

Delete `Apple2Forge.app`, then the folders in the table above. If you chose your own library location, delete that folder too.
