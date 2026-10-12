# Third-party notices

## apple2tc

The emulator `a2emu` and the recompiler `apple2tc` come from [tmikov/apple2tc](https://github.com/tmikov/apple2tc). The commit used is pinned in [`vendor/apple2tc.COMMIT`](vendor/apple2tc.COMMIT), and this project's changes are in [`vendor/patches/`](vendor/patches/).

```
MIT License

Copyright (c) 2021 Tzvetan Mikov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## sokol

The emulator window, input and graphics use sokol (part of apple2tc). This project patches `sokol_app.h` so the emulator window doesn't take over the menu bar ([`vendor/patches/a2emu-menu-bar.patch`](vendor/patches/a2emu-menu-bar.patch)).

```
zlib/libpng license

Copyright (c) 2018 Andre Weissflog

This software is provided 'as-is', without any express or implied warranty.
In no event will the authors be held liable for any damages arising from the
use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not
    claim that you wrote the original software. If you use this software in a
    product, an acknowledgment in the product documentation would be
    appreciated but is not required.

    2. Altered source versions must be plainly marked as such, and must not
    be misrepresented as being the original software.

    3. This notice may not be removed or altered from any source
    distribution.
```

## nlohmann/json

apple2tc uses [nlohmann/json](https://github.com/nlohmann/json):

```
MIT License 

Copyright (c) 2013-2021 Niels Lohmann

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apple firmware

- **No Apple II system ROM is in this repository or in the released app.** The emulator refuses to start without a ROM file you install yourself: see [Installing ROMs](docs/installing-roms.md).
- **The released app does contain two pieces of Apple-derived firmware data**, both from upstream apple2tc and compiled into the bundled `a2emu`:
  1. **The 256-byte Disk II controller boot PROM** (the P5 "boot 0" code at `$C600`), from `lib/a2io/disk2.c`.
  2. **The 2 KB Apple ][ text font**, from `lib/a2io/font.cpp`. Upstream notes that it is adapted from apple2js's `apple2_char.ts`, which reproduces the Apple ][ character-generator ROM. It draws 40-column text on the Apple ][+.

  Neither is in this repository's source files. Loading both from files you supply, as the system ROMs already are, is planned.
- Apple, Apple II, Apple ][+, Apple //e and Disk II are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple.

## Disk images

No disk images are in this repository or in the app. The library download fetches images from the [Asimov archive mirror](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/) onto your Mac, when you ask for it. The software on those images belongs to its copyright holders. The archive, the mirror and the publishers are credited in [Credits](docs/credits.md).
