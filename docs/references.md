# Technical references

Apple2Forge doesn't rewrite Apple's software. The emulator runs Apple's own ROM firmware, which you supply, and emulates the hardware around it in software: the video display, the memory switches, the game port and the Disk II drive. That hardware behaviour has to match what Apple published, or the original programs misbehave.

This page lists the Apple documents the emulator was **checked against**, the page where each fact appears, and what was compared. Most of the emulator comes from the upstream [apple2tc](https://github.com/tmikov/apple2tc) project; the Apple //e support, the language card and the display modes were added by Apple2Forge. Where code was written from a source other than Apple, the last section says so.

Page numbers are the numbers printed on the page. The page in the PDF file is shown in brackets, because the scans include covers and front matter.

## Apple firmware the emulator runs

None of these ROMs are included in any Apple2Forge download. [Installing ROMs](installing-roms.md) explains how you supply them.

| Machine | Apple part numbers | How it was checked |
|---|---|---|
| Apple ][+ | 341-0011 to 341-0015 (Applesoft BASIC), 341-0020 (Autostart Monitor) | The fetch script downloads these six chip dumps from the [Apple II Documentation Project](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/) and joins them in address order into one 12 KB image. |
| Enhanced Apple //e | 342-0304-A ($C000–$DFFF) and 342-0303-A ($E000–$FFFF) | The 16 KB image Apple2Forge builds is byte-for-byte identical to the two chip dumps, and to Apple's later single-chip part 342-0349-B. |
| Enhanced Apple //e video ROM | 342-0265-A | The character ROM Apple2Forge uses for the //e is byte-for-byte identical to this chip dump. |

The Apple ][+ text font comes from a different source: see [Credits](credits.md) and [Third-party notices](../THIRD_PARTY_NOTICES.md#apple-firmware).

## Apple documentation

All four documents are scans in the [Apple //e folder](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/) of the Apple II Documentation Project.

### Apple //e Technical Reference Manual

Apple Computer, Inc. Addison-Wesley, 1985. ISBN 0-201-17720-X. [PDF scan](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/Manuals/Apple%20IIe%20Technical%20Reference%20Manual.pdf).

| Topic | Where | What was compared |
|---|---|---|
| Low-resolution colours | Table 2-6, p. 23 [57] | The emulator's 16 lo-res colours are in the table's order, from 0 Black to 15 White. The manual names the colours but gives no RGB values; the RGB values come from apple2tc. |
| High-resolution colours | p. 24–25 [58–59], Table 2-7 | Seven dots per byte, with bit 7 choosing the colour set. Dots in even columns are violet (blue when bit 7 is on) and dots in odd columns are green (orange when bit 7 is on), but only when both neighbouring dots are off. Two dots side by side are both white. The Smooth display follows these rules exactly; see [Display styles](#display-styles). |
| Double high-resolution colours | Table 2-8, p. 26 [60] | All 16 colours decode to the right colour. |
| Display pages | Table 2-9, p. 28 [62] | The text, lo-res and hi-res page addresses. |
| Display soft switches | Table 2-10, p. 29 [63] | TEXT, MIXED, PAGE2, HIRES, 80COL, ALTCHARSET, 80STORE and the double hi-res switch, plus the status reads at $C01A–$C01F. Two differences were found; see [Known differences](#known-differences). |
| Hand controls (paddles and joystick) | p. 42 [76] | Reading $C070 starts the timers for the four paddle inputs at $C064–$C067, which count for up to about 3 milliseconds. The emulator's longest count is 2,810 processor cycles, about 2.75 ms. |
| Monitor firmware routines | Table 3-1, p. 46–47 [80–81] | The entry points that the T2-hybrid runtime replaces with native code: HOME $FC58, COUT $FDED, CROUT $FD8E, VTABZ $FC24, CLEOLZ $FC9E and PRBL2 $F94A. |
| Bank-switched memory (language card) | Table 4-6, p. 82 [116] | The $C080–$C08F switches: read RAM or ROM, write-enable after two reads, and the two 4 KB banks at $D000. |
| Auxiliary memory | Table 4-7, p. 87 [121] | RAMRD, RAMWRT, ALTZP and 80STORE, and the matching status reads. |
| Video timing | p. 175 [209] | 65 processor cycles per line and 262 lines per frame (17,030 cycles), with lines 192–261 in vertical blanking. Reading $C019 gives a value below 128 during blanking, which programs use to change the screen without flicker. |
| Signature byte | Appendix C, p. 230 [264] | The ROM picker in Settings checks that $FBB3 is $EA in an Apple ][+ ROM and $06 in an Apple //e ROM. The byte at $FBC0 that tells an enhanced //e from an original //e or a //c isn't in these manuals. |

### Apple //e Technical Notes

Apple Developer Technical Support, revised November 1988. [PDF scan](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/Documentation/Apple%20IIe%20Technical%20Notes.pdf).

| Note | Where | What was compared |
|---|---|---|
| #3: Double High-Resolution Graphics | Pages 1–19 of the note [PDF 14–32] | How auxiliary and main memory bytes interleave across the screen, with the least significant bit leftmost, and the half-dot shift between double hi-res and ordinary hi-res (p. 4–5 of the note). The emulator's double hi-res decoder cites this note. |
| #3, Table 2: The Sixteen Colors | Page 19 of the note [PDF 32] | Every one of the 16 rows decodes to the colour the table names. |

### Apple //e Reference Manual Addendum: Monitor ROM Listings

Apple Computer, Inc., 1982. "For //e only." [PDF scan](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/Manuals/Apple%20IIe%20Reference%20Manual%20Addendum%20Monitor%20ROM%20Listings.pdf).

| Topic | Where | What was compared |
|---|---|---|
| Monitor ROM listing | p. 6–16 [12–22] | The listing shows the routines above at the same addresses, together with PREAD $FB1E, BASCALC $FBC1, VTAB $FC22, SETINV $FE80 and SETNORM $FE84. |

The T2-hybrid build of Number Munchers runs on the Apple ][+ ROM. Its source code cites the original *Apple II Reference Manual* for these routines; that manual wasn't re-checked here, but the routines are at the same addresses in the //e listing above.

### Apple //e Reference Manual

Apple Computer, Inc., 1982. [PDF scan](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/Manuals/Apple%20IIe%20Reference%20Manual.pdf). The original 1982 edition, for the unenhanced //e. Apple2Forge emulates the enhanced //e, so the 1985 Technical Reference Manual above was used wherever the two differ.

## Display styles

Apple2Forge offers two ways to draw the screen.

- **Smooth** (the default) draws clean, sharp pixels and colours them using the rules on p. 24–25 of the Technical Reference Manual: a lit dot next to another lit dot is white, a lone lit dot takes the colour of its column, and a dark dot between two dots of the same colour is filled with that colour, so coloured areas look solid.
- **Classic** keeps the original apple2tc drawing, which is softer and shows the coloured fringes at the edges of white areas that real colour monitors showed.

Neither style changes how a program runs. Only the drawing on screen differs.

## Known differences

Checking the emulator against the manual found two small differences. Neither has been fixed yet; both are tracked for a later release.

- **RDIOUDIS ($C07E):** Table 2-10 says bit 7 reads as 1 when the IOUDIS switch is **off**. The emulator always reports bit 7 as 1 and behaves as though IOUDIS is always on.
- **Paddle timer on $C07E and $C07F:** The manual says that accessing any address from $C070 to $C07F starts the paddle timers. In the emulator's //e mode, accesses to $C07E and $C07F don't.

## Other references

The upstream apple2tc project cites the first three sources in its own code. They weren't re-checked for Apple2Forge.

| Source | Used for |
|---|---|
| Jim Sather, *Understanding the Apple IIe* (Quality Software, 1985) | Disk II encoding and decoding tables |
| Don Worth and Pieter Lechner, *Beneath Apple DOS* (Quality Software, 1981) | Disk II encoding and decoding tables, and the DOS 3.3 disk layout |
| [ProDOS 8 Technical Reference Manual](https://prodos8.com/docs/techref/) | ProDOS disk layout |
| Western Design Center, *W65C02S datasheet* | Apple2Forge's 65C02 support: in decimal mode, the 65C02 sets valid flags and takes one extra cycle. ProDOS 8 2.x uses this to tell a 65C02 from a 6502. |

## Hardware documents not used

The [Apple //e schematics (050-0051-D)](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Computers/Apple%20II/Apple%20IIe/Schematics/Apple%20IIe%20-%20Schematics%20050-0051-D.pdf), the timing-chip logic equations and Apple's technical repair procedures describe circuit-level signals. Apple2Forge emulates the computer at the level programs can see (memory, switches and the screen), so these weren't needed. They're listed here for anyone who wants to go deeper.
