# Educational library

The **Library** menu lists about 1,200 educational titles from the Asimov archive's educational collection, grouped by subject. They are downloaded onto your Mac only when you ask.

## Download

1. Choose **Library ▸ Download Educational Library…**.
2. Choose where to keep it:
   - **Use Default Location**: `~/Library/Application Support/Apple2Forge/library/`.
   - **Choose Location…**: any folder you can write to, except inside an app bundle. An external drive works.
3. The main window shows progress through three steps:
   1. **Downloading disk images**: about 2,300 `.dsk` files, about 330 MB. Images whose name contains "4am" (copy-protection cracks of other releases) are skipped.
   2. **Building the catalog**: groups disks and sides into titles, and sorts the titles into subjects.
   3. **Checking which machine each title needs**: boots every title for 30 seconds without a window. It tries the Apple ][+ first, and also the Apple //e if the ][+ boot fails or the title's name mentions the //e. Titles that show only a blank screen get up to 2 minutes, for slow loaders. This step needs all three [ROM files](installing-roms.md) and is skipped without them.

**Cancel** stops the download. Choosing **Download Educational Library…** again resumes it; files already downloaded are kept.

Apple2Forge remembers the folder. If you move or rename it in the Finder, Apple2Forge still finds it.

## Menu commands

| Command | What it does |
|---|---|
| **Library ▸ *Subject* ▸ *Title*** | Starts the title, with all its disks inserted |
| **Download Educational Library…** | Downloads, or resumes, and rebuilds the catalog |
| **Change Library Location…** | Points Apple2Forge at another folder; it doesn't move files. If that folder has no library yet, download into it |
| **Show Library in Finder** | Opens the library folder |
| **Rebuild Catalog** | Rebuilds the menu from the downloaded files, without downloading |

## Subjects

Titles are sorted into ten subjects: **Math, History, Social Studies, Science, Geography, Health, Arts, Writing, Literature, Reading**. They are sorted by file-name rules (`library/subject_rules.json`) plus a list of fixes by title (`library/subject_overrides.json`). Titles that match no subject are left out of the menu.

## Which machine a title runs on

Each title is started on the machine it needs. The first of these that applies decides:

1. A fix in `library/subject_overrides.json`.
2. The result of the compatibility check after download.
3. Hints in the file name, such as "128K", "//e" or "enhanced".

| Result | In the menu | Meaning |
|---|---|---|
| Apple ][+ (64K) | *Title* | Starts on an Apple ][+ with a 16K Language Card |
| Apple //e (128K) | *Title* — Apple //e | Starts on an enhanced Apple //e |
| Not a startup disk | *Title* — not a startup disk (greyed out) | Neither machine found a boot sector; the disk is used from within another title |
| Unknown | *Title* | Booted on neither machine within the time limit. It is still offered on the Apple ][+: it may work, or the image may be damaged. The reason is recorded in `compat.json` |

## Library folder contents

```
library/
├── disks/          # the downloaded .dsk images
├── manifest.json   # what was downloaded, with sizes and SHA-256 checksums
├── library.json    # the catalog: titles, subjects, disks, machine
└── compat.json     # results of the compatibility check
```

## Multi-disk titles

Disks that belong together (Side A/B, Disk 1/2, Program/Data) are grouped into one title. The first two sides start in drives 1 and 2; the **Disk** menu swaps the rest. See [Disk swapping](disk-swapping.md).
