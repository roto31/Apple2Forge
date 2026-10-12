# Legal and ROMs

Apple2Forge's own code is MIT-licensed ([LICENSE](../LICENSE)). The Apple II firmware and the software on the disk images are not part of it.

## What is and isn't included

| Item | In this repository | In the released app | How you get it |
|---|---|---|---|
| Apple ][+ / //e system ROMs | No | No | You install them (first-run dialog, Settings, or script): [Installing ROMs](installing-roms.md) |
| Disk II boot PROM (256 bytes) | No | **Yes**, compiled into `a2emu` from upstream apple2tc | — |
| Apple ][ text font (2 KB, from the character-generator ROM) | No | **Yes**, compiled into `a2emu` from upstream apple2tc | — |
| Educational disk images | No | No | **Library ▸ Download Educational Library…** downloads them onto your Mac |
| Number Munchers (T2 tools) | No | No | Your own copy of the disk |
| Apps built from your disks | No | No | Built on your Mac into the ignored `work/` folder |

The build checks every byte of the emulator and of the app bundle against the Apple ][+ system ROM, and refuses to finish if any of it is found. The release process also scans the source and the app against the //e ROMs. Two known exceptions are compiled in from upstream apple2tc: the Disk II boot PROM and the Apple ][ text font. Both are listed in the [third-party notices](../THIRD_PARTY_NOTICES.md#apple-firmware). Loading both from files you supply, as the system ROMs already are, is planned.

## Your responsibilities

- Install and use Apple ROMs only if you are entitled to, for example because you own the machine.
- Download and use disk images only where you have the right to.
- Don't redistribute ROMs, disk images, or apps built from disk images. An app built from a disk contains the software on it; each such app carries this notice in `Contents/Resources/NOTICE.txt`.

## Trademarks

Apple, Apple II, Apple ][+, Apple //e and Disk II are trademarks of Apple Inc. MECC, Number Munchers and the other programs and publishers in the library belong to their respective owners. This project is not affiliated with or endorsed by any of them. The sources and publishers are credited in [Credits](credits.md).
