# Getting started

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel. From 0.4.0 the release is a universal app. Its Intel half has been tested under Rosetta on Apple silicon, not yet on an Intel Mac. Releases 0.3.0 and earlier are Apple silicon (arm64) only.
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

From 0.4.0 the app is signed with a Developer ID and notarized by Apple. Open it like any app downloaded from the internet: macOS asks once whether you want to open it; choose **Open**.

Releases 0.3.0 and earlier, and apps built on another Mac (for example a T1 app copied over by AirDrop), are ad-hoc signed and not notarized, so macOS blocks their first launch:

1. Open the app. macOS says it can't verify the developer; choose **Done**.
2. Open **System Settings ▸ Privacy & Security**, scroll to the message about the app, and choose **Open Anyway**.
3. Open the app again and confirm.

After that it opens normally.

## First-run setup (ROMs and library)

The first time Apple2Forge opens after macOS lets it run, it asks two questions:

1. **ROMs** — You can download and install the Apple ][+ and enhanced //e ROMs automatically (from the same mirror as [Installing ROMs](installing-roms.md#option-2-with-the-script-recommended-for-developers)), choose your own ROM files with the file picker, or skip for now. Use ROMs only if you are entitled to.
2. **Educational library** — You can download the games and applications to the default folder (`~/Library/Application Support/Apple2Forge/library/`), or choose **Not Now**. If you skip, the **Library** tab shows a reminder and **Download Now…**; you can also use **Library ▸ Download Educational Library…** any time.

This setup runs once. To see it again, delete the `firstRunCompleted` key from Apple2Forge's preferences, or pass `--skip-first-run` when launching from Terminal to bypass it (for scripts and tests).

## First steps

![Apple2Forge's Build tab with its setup check](images/build-tab-setup-check.png)

Apple2Forge opens on its **Build** tab, which turns disk images into Mac apps. It needs a source checkout of this repository, and its setup check says "Project folder: not found" until you choose one in **Settings**. See [Apple2Forge](apple2forge.md#build-tab). To play the library, you don't need it: use the **Library** tab or menu.

1. **Install the ROMs**: the first-run dialog can do this for you, or see [Installing ROMs](installing-roms.md). Without them, titles can't start, and the post-download check that picks each title's machine is skipped.
2. **Download the library**: the first-run dialog can download to the default location, or choose **Library ▸ Download Educational Library…** later. The main window shows progress; see [Educational library](library.md).
3. **Play**: choose a subject in the **Library** menu, then a title. The game opens in its own window. See [Playing games](playing-games.md).

## Where Apple2Forge keeps things

| What | Where |
|---|---|
| ROMs (you install them) | `~/Library/Application Support/Apple2Forge/roms/` |
| Educational library (default) | `~/Library/Application Support/Apple2Forge/library/` |
| Logs | `~/Library/Logs/Apple2Forge/` (`emulator.log` for the game window) |
| Launch links (window titles) | `~/Library/Caches/Apple2Forge/launch/` |
| Build tab output | `~/Library/Application Support/Apple2Forge/builds/` |

Nothing is written inside `Apple2Forge.app`.

## Uninstall

Delete `Apple2Forge.app`, then the folders in the table above. If you chose your own library location, delete that folder too.
