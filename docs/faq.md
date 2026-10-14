# FAQ

## Why doesn't Apple2Forge include the ROMs or the games?

They are copyrighted by Apple and by the software publishers. Apple2Forge downloads disk images only when you ask, and you install ROMs yourself. See [Legal and ROMs](legal-and-roms.md).

## Why don't my scores or records save?

The emulator doesn't write to disk images yet: every disk is write-protected. Games that save, such as hall-of-fame lists or student records, either show a write-protect error or lose the data when you quit. Saving into a personal copy of each disk is planned.

## Which machine does a title run on?

The one it needs: an Apple ][+ (64K) for most titles, or an enhanced Apple //e (128K) for titles that need it. The choice comes from test-booting each title after download. See [Educational library](library.md#which-machine-a-title-runs-on).

## Can I use my own disk images?

Not in the Library menu: it lists only the downloaded collection from the [Asimov archive's educational folder](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/) (see [Credits](credits.md)).

For your own disks, there are two options. Apple2Forge's **Build** tab wraps an Apple ][+ disk into a Mac app that needs your ROM installed to run; it needs a source checkout of this repository ([Apple2Forge](apple2forge.md#build-tab)). The [command-line tools](command-line-tools.md) do the same, or run a disk in `a2emu` directly. See [Make a Mac app from your disk](make-a-mac-app-from-your-disk.md).

## Why does the Build tab say the project folder was not found?

The Build tab runs the toolkit's scripts, which aren't inside the app. Clone this repository, run its setup, and choose the folder in **Apple2Forge ▸ Settings… ▸ Project folder**. See [Apple2Forge](apple2forge.md#set-up-once). The Library tab doesn't need it.

## How do Apple2Forge and the toolkit relate?

The [native conversion toolkit](native-conversion.md) (the scripts in `tools/`) is the core of the project. [Apple2Forge](apple2forge.md) is a separate app bundled with it. Its Library tab works on its own. Its Build tab is a front end for the toolkit.

## Can I move the library to another drive?

Yes. Move the folder in the Finder: Apple2Forge remembers folders by bookmark, so it usually follows. You can also point it at the new place with **Library ▸ Change Library Location…**.

## How much space does it need?

About 330 MB for the disk images, plus a few MB for the catalog and logs.

## Does Apple2Forge send anything over the network?

Only during **Download Educational Library…**, which downloads the disk-image list and the images from `mirrors.apple2.org.za` over HTTPS. There are no analytics and no update checks.

## Why do the games look sharper than a real Apple II?

Apple2Forge draws games in the **Smooth** style by default, with sharp pixels and solid colours, because that's what players used to modern screens expect. The colours still follow the rules in Apple's own manual; see [Technical references](references.md#display-styles). If you prefer the softer picture and colour fringes of an Apple II on a colour monitor, choose **Classic** under **Apple2Forge ▸ Settings… ▸ Display**. See [Playing games](playing-games.md#display-style).

## How do I know the emulation is accurate?

The emulated hardware was checked against Apple's *Apple //e Technical Reference Manual*, *Apple //e Technical Notes* and *Monitor ROM Listings*. [Technical references](references.md) lists each document, page and what was compared, including two small differences that haven't been fixed yet.

## Is there sound?

Yes, the Apple II speaker is emulated.

## Is the app notarized?

From 0.4.0, yes: releases are signed with a Developer ID and notarized by Apple. Releases 0.3.0 and earlier, an app you [build yourself](building-from-source.md), and the T1/T2 apps the toolkit makes are ad-hoc signed; see [First launch](getting-started.md#first-launch).

## What are T1 and T2?

Two ways of turning a disk into a Mac app. **T1** wraps the original program in an Apple ][+ emulator. It accepts any 140K disk the analyzer supports, but has been tested end to end only with Number Munchers. **T2-hybrid** translates the program's 6502 code to C and compiles it natively, with an interpreter for any code that wasn't translated; its scripts work only for Number Munchers v1.3. See [Native conversion toolkit](native-conversion.md) and [Make a Mac app from your disk](make-a-mac-app-from-your-disk.md).

## Does it run on an Intel Mac?

Yes, from 0.4.0. The release, the bundled emulator and the T1/T2 apps the toolkit builds are universal (arm64 + x86_64). The Intel half has been tested under Rosetta on Apple silicon, not yet on an Intel Mac; reports are welcome. Releases 0.3.0 and earlier are Apple silicon only.
