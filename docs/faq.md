# FAQ

## Why doesn't Apple2Forge include the ROMs or the games?

They are copyrighted by Apple and by the software publishers. Apple2Forge downloads disk images only when you ask, and you install ROMs yourself. See [Legal and ROMs](legal-and-roms.md).

## Why don't my scores or records save?

The emulator doesn't write to disk images yet: every disk is write-protected. Games that save, such as hall-of-fame lists or student records, either show a write-protect error or lose the data when you quit. Saving into a personal copy of each disk is planned.

## Which machine does a title run on?

The one it needs: an Apple ][+ (64K) for most titles, or an enhanced Apple //e (128K) for titles that need it. The choice comes from test-booting each title after download. See [Educational library](library.md#which-machine-a-title-runs-on).

## Can I use my own disk images?

The library comes from the Asimov archive's educational collection. For your own disks, the [command-line tools](command-line-tools.md) can run them in `a2emu` directly, or turn one into a standalone Mac app.

## Can I move the library to another drive?

Yes. Move the folder in the Finder: Apple2Forge remembers folders by bookmark, so it usually follows. You can also point it at the new place with **Library ▸ Change Library Location…**.

## How much space does it need?

About 330 MB for the disk images, plus a few MB for the catalog and logs.

## Does Apple2Forge send anything over the network?

Only during **Download Educational Library…**, which downloads the disk-image list and the images from `mirrors.apple2.org.za` over HTTPS. There are no analytics and no update checks.

## Is there sound?

Yes, the Apple II speaker is emulated.

## Why is the app not notarized?

Notarization needs a paid Apple Developer ID. Releases are ad-hoc signed instead; see [First launch](getting-started.md#first-launch). You can also [build it yourself](building-from-source.md).

## What are T1 and T2?

Two ways of turning a disk into a Mac app. **T1** wraps the original program in an emulator. **T2-hybrid** translates the program's 6502 code to C and compiles it natively, with an interpreter for any code that wasn't translated. See [Command-line tools](command-line-tools.md).
