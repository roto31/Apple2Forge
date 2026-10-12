# Credits

Apple2Forge exists because other people preserved this software and wrote the tools it builds on.

## Educational software

### The Asimov archive

Every title in the Library menu comes from the **Asimov Apple II archive** (`ftp.apple.asimov.net`), the long-running public archive of Apple II software and documentation. Its main home is [asimov.applefritter.com](https://asimov.applefritter.com/). Thank you to the archive's maintainers, to the people who imaged the original disks and uploaded them, and to the mirror operators who keep it available.

### Where Apple2Forge downloads from

**Library ▸ Download Educational Library…** (and `tools/07_fetch_edu_library.sh`) downloads from this folder of the archive, on the APPLE2.ORG.ZA mirror:

**<https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/>**

It takes the `.dsk` images in that folder and its subfolders, except those with "4am" in the file name: 2,277 images on the last download. Thank you to [APPLE2.ORG.ZA](https://mirrors.apple2.org.za/) for hosting the mirror. The archive's own mirror list (as of February 2025) names it as a full mirror, alongside asimov.applefritter.com and others: see [MIRROR.LIST.txt](https://mirrors.apple2.org.za/ftp.apple.asimov.net/MIRROR.LIST.txt).

Apple2Forge doesn't copy or redistribute these images. They are downloaded onto your Mac only when you ask, straight from the mirror.

### The original publishers

The programs belong to the companies and authors who made them for schools in the 1980s and early 1990s. The library's file names name the publisher on 808 of the 2,277 images. Those publishers are:

| Publisher | Images with the name in the file name |
|---|---|
| MECC (Minnesota Educational Computing Consortium) | 517 |
| Scholastic, including *Microzine* | 217 |
| Sunburst | 19 |
| Hartley | 11 |
| Gessler | 8 |
| Wings for Learning | 4 |
| Spinnaker | 3 |
| Milliken | 3 |
| DLM | 2 |
| Focus Media | 2 |
| EduWare | 2 |
| Broderbund | 1 |

19 more file names mark the program as public domain ("PD"). The other images don't name a publisher in the file name, so they aren't counted here. The counts come from matching file names, not from the disks' contents.

All rights in this software stay with its copyright holders. Apple2Forge isn't affiliated with or endorsed by any of them. See [Legal and ROMs](legal-and-roms.md).

## Software Apple2Forge builds on

| Project | Author | Used for | Licence |
|---|---|---|---|
| [apple2tc](https://github.com/tmikov/apple2tc) | Tzvetan Mikov | The `a2emu` emulator, and the 6502-to-C translator behind T2-hybrid | MIT |
| [sokol](https://github.com/floooh/sokol) | Andre Weissflog | The emulator's window, graphics, input and audio | zlib |
| [nlohmann/json](https://github.com/nlohmann/json) | Niels Lohmann | JSON support in apple2tc's `a2mcp` component, included with apple2tc | MIT |
| [apple2js](https://github.com/whscullin/apple2js) | Will Scullin | Source of the emulator's Apple ][ text font, by way of apple2tc | See [third-party notices](../THIRD_PARTY_NOTICES.md#apple-firmware) |

Full licence texts are in [third-party notices](../THIRD_PARTY_NOTICES.md).

## Apple

Apple, Apple II, Apple ][+, Apple //e and Disk II are trademarks of Apple Inc. The Apple II ROMs that Apple2Forge needs are Apple's. You supply your own copy: see [Installing ROMs](installing-roms.md).
