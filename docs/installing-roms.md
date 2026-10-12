# Installing ROMs

Apple2Forge never includes Apple's system ROMs. You install them once, and the emulator loads them each time a game starts.

> Use these ROMs only if you are entitled to, for example because you own the machine. Never redistribute them. See [Legal and ROMs](legal-and-roms.md).

## Which files

All of them go in `~/Library/Application Support/Apple2Forge/roms/`:

| File | Size | Needed for |
|---|---|---|
| `apple2plus.rom` | 12,288 bytes (`$D000`–`$FFFF`) | Titles that run on an Apple ][+ (most of the library) |
| `apple2e-enhanced.rom` | 16,384 bytes (`$C000`–`$FFFF`) | Titles that need 128K or an enhanced //e |
| `apple2e-video.rom` | //e video ROM (342-0265-A) | //e titles: lowercase and MouseText characters |

The library's compatibility check needs all three. Without them it is skipped, and each title uses the machine its file name suggests.

## Option 1: first launch in Apple2Forge

When you open Apple2Forge for the first time, choose **Download and Install** on the ROM question. The app runs the same fetch script as below (Apple ][+ and enhanced //e, including the video ROM) and copies the files into `~/Library/Application Support/Apple2Forge/roms/`. Choose **Choose My Own Files…** to pick ROM images yourself, or **Skip for Now** and use Settings or the script later.

## Option 2: with the script (recommended for developers)

The repository has a script that downloads the original chip images from the Apple II Documentation Project mirror (`mirrors.apple2.org.za`), assembles the ROM files and installs them:

```bash
git clone https://github.com/roto31/Apple2Forge.git
cd Apple2Forge
tools/05_fetch_rom.sh --install                 # Apple ][+
tools/05_fetch_rom.sh --model=iie --install     # enhanced Apple //e + video ROM
```

- `--install` copies the files to the folder above. If a different file is already there, it is first backed up as `<name>.backup-YYYYMMDD_HHMMSS`.
- `--dry-run` shows what would be downloaded, without changing anything.
- The downloaded chips and assembled ROMs stay in the clone's `roms/` folder, which Git ignores.

## Option 3: by hand

If you already have ROM images in the formats above, create the folder and copy them in under exactly these names:

```bash
mkdir -p ~/Library/Application\ Support/Apple2Forge/roms
cp apple2plus.rom apple2e-enhanced.rom apple2e-video.rom ~/Library/Application\ Support/Apple2Forge/roms/
```

## Option 4: in Settings

Choose **Apple2Forge ▸ Settings…**, then **Machine**. Each ROM has a **Choose…** button. Apple2Forge checks the file before copying it into the ROM folder:

- **Size:** 12,288 bytes for the Apple ][+ (a 20,480-byte file that also holds Integer BASIC is accepted; its last 12,288 bytes are used), 16,384 bytes for the //e (a 32,768-byte file holding one is accepted), and 4,096 bytes for the //e video ROM.
- **Machine:** the ID bytes the Apple II Monitor keeps at `$FBB3` (and `$FBC0` on a //e). An original, unenhanced //e or a //c ROM is refused, because Apple2Forge emulates the Apple ][+ and the enhanced //e only.

A file that matches Apple's original chips is shown with their part numbers, for example *Apple 341-0011 to 341-0015 and 341-0020*. A file it replaces is moved to a `backup-YYYYMMDD_HHMMSS` folder in the ROM folder, and **Restore Previous** puts the newest backup back.

## Check

Start any title from the **Library** menu. If a ROM is missing, Apple2Forge says which file and machine, for example: *The Apple ][+ ROM is not installed (apple2plus.rom)*.
