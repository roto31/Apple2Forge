"""Build library.json: group downloaded disk images into titles and subjects.

Usage: python3 -I tools/lib/library_catalog.py LIBRARY_DIR RULES_DIR

LIBRARY_DIR holds manifest.json and disks/ (from tools/lib/edu_fetch.py) and,
optionally, compat.json (from the compatibility sweep). RULES_DIR holds
subject_rules.json, subject_overrides.json and grouping_overrides.json.

Writes LIBRARY_DIR/library.json and LIBRARY_DIR/review/{grouping,subject}-review.md.

Grouping model: a title is one or more disks; each disk has side A and an
optional side B. Labels understood (any case, space/underscore/dash):
"side A-D" or "side 1-4" (C/D and 3/4 are disk 2), "disk 1-9", "disk A-C",
"disk 1a/1b", "N of M". An image with no label is disk 1 side A. Disk numbers
of 10 or more are issue numbers and stay in the title. "data disk" style
images join the program title with the same name in the same folder.

Exit codes: 0 written, 2 bad input.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field

SCHEMA_VERSION = 1
SUBJECTS = ["Math", "History", "Social Studies", "Science", "Geography",
            "Health", "Arts", "Writing", "Literature", "Reading"]
SIDE_NAMES = "AB"
SIDES_PER_DISK = 2
MAX_DISK_INDEX = 9

REQUIREMENT_IIPLUS = "IIplus64K"
REQUIREMENT_IIE = "IIe128K"
REQUIREMENT_NOBOOT = "noboot"
REQUIREMENT_UNKNOWN = "unknown"

PARENTHETICAL = re.compile(r"\(([^)]*)\)")
SIDE_TOKEN = re.compile(r"(?<![a-z0-9])side[ _-]*([a-d1-4])(?![a-z0-9])", re.I)
DISK_NUMBER_TOKEN = re.compile(
    r"(?<![a-z0-9])disk[ _-]*([1-9])([ab])?(?:[ _-]*of[ _-]*[1-9])?(?![a-z0-9])", re.I)
DISK_LETTER_TOKEN = re.compile(r"(?<![a-z0-9])disk[ _-]*([a-c])(?![a-z0-9])", re.I)
N_OF_M_TOKEN = re.compile(r"(?<![a-z0-9])([1-9])[ _-]*of[ _-]*[1-9](?![a-z0-9])", re.I)
SUPPORT_DISK_TOKEN = re.compile(
    r"(?<![a-z])(data|question|student|teacher|lesson|study|backgrounds?)[ _-]+disk"
    r"(?:[ _-]*([1-9])(?![a-z0-9]))?(?![a-z])", re.I)
DISK_SIDE_SHORT_TOKEN = re.compile(r"(?<![a-z0-9])d([1-9])[ _-]?s([1-4])(?![a-z0-9])", re.I)
SIDE_SHORT_TOKEN = re.compile(r"(?<![a-z0-9])s([1-4])$", re.I)
NOISE_WORDS = re.compile(r"(?<![a-z])(cracked|crack)(?![a-z])", re.I)
PROGRAM_SUFFIX = re.compile(r"(?:[ _-]+(?:program|boot|master)[ _-]+disk|[ _]*-[ _]*programs?)$", re.I)
IIE_HINT = re.compile(r"128k|//e|\biie\b|\benhanced\b|65c02|80[ -]?col|double hi-?res|\biigs\b", re.I)
NOBOOT_HINT = re.compile(r"no[ _-]?boot", re.I)
SEPARATORS = " -_.,"


@dataclass
class DiskImage:
    path: str            # relative to LIBRARY_DIR/disks
    sha256: str
    folder: str
    stem: str
    title: str           # display title, tokens removed
    key: str             # grouping key
    notes: list[str]
    disk: int            # 1-based
    side: int            # 0 = A, 1 = B
    label: str           # text after the disk/side token, e.g. "program"
    explicit: bool       # had a disk or side label
    support: bool        # a data/question/... disk


@dataclass
class Title:
    folder: str
    title: str
    key: str
    notes: list[str] = field(default_factory=list)
    images: list[DiskImage] = field(default_factory=list)
    review: list[str] = field(default_factory=list)


def normalize_key(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def tidy(text: str) -> str:
    text = re.sub(r"\s+", " ", text.replace("_", " ")).strip(SEPARATORS)
    return re.sub(r"\s+-\s*$", "", text)


def is_position_label(text: str) -> bool:
    return any(p.search(text) for p in (SIDE_TOKEN, DISK_NUMBER_TOKEN, N_OF_M_TOKEN, DISK_SIDE_SHORT_TOKEN))


def side_index(token: str) -> int:
    token = token.lower()
    return "abcd".index(token) if token.isalpha() else int(token) - 1


def split_at(text: str, match: re.Match[str]) -> tuple[str, str]:
    return text[:match.start()], text[match.end():]


def parse_image(path: str, sha256: str) -> DiskImage:
    """Reads title, disk number and side from one file name."""
    folder, _, filename = path.rpartition("/")
    stem = re.sub(r"\.dsk$", "", filename, flags=re.I)
    notes = [n.strip() for n in PARENTHETICAL.findall(stem) if not is_position_label(n)]
    # "(Disk 1 of 2)" is a position, not a note: keep its words in the text.
    text = PARENTHETICAL.sub(lambda m: f" {m.group(1)} " if is_position_label(m.group(1)) else " ", stem)
    text = tidy(NOISE_WORDS.sub(" ", text))
    disk, side, explicit, label = 1, 0, False, ""

    short_match = DISK_SIDE_SHORT_TOKEN.search(text)
    if short_match:
        before, after = split_at(text, short_match)
        text = tidy(f"{before} disk {short_match.group(1)} side {short_match.group(2)} {after}")
    else:
        text = SIDE_SHORT_TOKEN.sub(lambda m: f"side {m.group(1)}", text)

    side_match = SIDE_TOKEN.search(text)
    if side_match:
        explicit = True
        index = side_index(side_match.group(1))
        disk, side = 1 + index // SIDES_PER_DISK, index % SIDES_PER_DISK
        before, after = split_at(text, side_match)
        text, label = before, tidy(after)

    support_match = SUPPORT_DISK_TOKEN.search(text)
    support = bool(support_match)
    if support_match:
        if support_match.group(2):
            explicit = True
            disk = int(support_match.group(2)) + (disk - 1)
        before, after = split_at(text, support_match)
        label = tidy(" ".join(x for x in (f"{support_match.group(1)} disk", tidy(after), label) if x))
        text = before

    disk_match = None if support else (
        DISK_NUMBER_TOKEN.search(text) or DISK_LETTER_TOKEN.search(text) or N_OF_M_TOKEN.search(text))
    if disk_match:
        explicit = True
        number = disk_match.group(1)
        disk_number = int(number) if number.isdigit() else "abc".index(number.lower()) + 1
        disk = disk_number + (disk - 1)
        if disk_match.re is DISK_NUMBER_TOKEN and disk_match.group(2):
            side = side_index(disk_match.group(2))
        before, after = split_at(text, disk_match)
        text = before
        label = tidy(" ".join(x for x in (tidy(after), label) if x))

    title = tidy(PROGRAM_SUFFIX.sub("", tidy(text))) or tidy(PARENTHETICAL.sub(" ", stem))
    return DiskImage(path=path, sha256=sha256, folder=folder, stem=stem, title=title,
                     key=normalize_key(title), notes=notes, disk=disk, side=side,
                     label=label, explicit=explicit, support=support)


def group_images(images: list[DiskImage]) -> list[Title]:
    """Groups by folder + title key; splits groups whose positions collide."""
    groups: dict[tuple[str, str], list[DiskImage]] = {}
    for image in images:
        if not image.support:
            groups.setdefault((image.folder, image.key), []).append(image)
    titles: list[Title] = []
    for (folder, key), members in groups.items():
        titles.extend(split_collisions(folder, key, members))
    attach_support_disks(titles, [i for i in images if i.support])
    return titles


def variant_of(image: DiskImage) -> str:
    """The file name with its disk/side labels blanked: copies named alike stay together."""
    pattern = image.stem
    for placeholder, token in (("#DS", DISK_SIDE_SHORT_TOKEN), ("#S", SIDE_TOKEN), ("#D", DISK_NUMBER_TOKEN),
                               ("#D", DISK_LETTER_TOKEN), ("#D", N_OF_M_TOKEN), ("#S", SIDE_SHORT_TOKEN)):
        pattern = token.sub(placeholder, pattern)
    return pattern.lower()


def split_collisions(folder: str, key: str, members: list[DiskImage]) -> list[Title]:
    positions = [(m.disk, m.side) for m in members]
    if len(set(positions)) == len(positions):
        return [make_title(folder, key, members, [])]
    variants: dict[str, list[DiskImage]] = {}
    for member in members:
        variants.setdefault(variant_of(member), []).append(member)
    titles = []
    for number, (variant, variant_members) in enumerate(sorted(variants.items()), start=1):
        reason = f"same title had overlapping disk/side labels; split into release {number} of {len(variants)}"
        if len({(m.disk, m.side) for m in variant_members}) != len(variant_members):
            # Still colliding: one title per image so nothing is lost.
            for alt, member in enumerate(variant_members, start=1):
                titles.append(make_title(folder, f"{key}~{number}.{alt}", [member],
                                         [reason + "; still overlapping, kept as separate entries"]))
            continue
        titles.append(make_title(folder, f"{key}~{number}", variant_members, [reason]))
    return titles


def make_title(folder: str, key: str, members: list[DiskImage], review: list[str]) -> Title:
    members.sort(key=lambda m: (m.disk, m.side, m.stem.lower()))
    first = members[0]
    notes = list(dict.fromkeys(n for m in members for n in m.notes))
    title = Title(folder=folder, title=first.title, key=key, notes=notes, images=members, review=list(review))
    if (first.disk, first.side) != (1, 0):
        title.review.append(f"no disk 1 side A; boots from disk {first.disk} side {SIDE_NAMES[first.side]}")
    labels = {m.label for m in members if m.label}
    if len(labels) > 1 and len({m.disk for m in members}) > 1:
        title.review.append("disks carry different labels; check they are one program, not separate lessons")
    return title


def attach_support_disks(titles: list[Title], support: list[DiskImage]) -> None:
    """Data disks follow their program's disks, keeping their own disk/side order."""
    by_key = {(t.folder, t.key): t for t in titles}
    disk_base = {id(t): max(m.disk for m in t.images) for t in titles}
    used: dict[int, set[tuple[int, int]]] = {}
    for image in sorted(support, key=lambda i: (i.label.lower(), i.disk, i.side)):
        owner = by_key.get((image.folder, image.key))
        if owner is None:
            owner = Title(folder=image.folder, title=f"{image.title} (support disks)", key=image.key + "~support",
                          review=["support disks with no matching program disk in this folder"])
            titles.append(owner)
            by_key[(image.folder, image.key)] = owner
            disk_base[id(owner)] = 0
        taken = used.setdefault(id(owner), {(m.disk, m.side) for m in owner.images})
        position = (disk_base[id(owner)] + image.disk, image.side)
        while position in taken:
            position = (position[0] + 1, image.side)
        taken.add(position)
        image.disk, image.side = position
        owner.images.append(image)
        owner.images.sort(key=lambda m: (m.disk, m.side, m.stem.lower()))


def requirement_hint(title: Title) -> str:
    text = " ".join([title.title] + title.notes + [m.stem for m in title.images])
    boot = title.images[0]
    if NOBOOT_HINT.search(" ".join(boot.notes + [boot.stem])):
        return REQUIREMENT_NOBOOT
    if IIE_HINT.search(text):
        return REQUIREMENT_IIE
    return REQUIREMENT_UNKNOWN


def load_json(path: str, default: object) -> object:
    if not os.path.isfile(path):
        return default
    with open(path) as handle:
        return json.load(handle)


class SubjectRules:
    """Ordered rules; the first match wins. A null subject stops matching (left for review)."""

    def __init__(self, rules: list[dict[str, str | None]]):
        self.rules = []
        for rule in rules:
            if rule["subject"] is not None and rule["subject"] not in SUBJECTS:
                raise ValueError(f"unknown subject in subject_rules.json: {rule['subject']}")
            self.rules.append((re.compile(rule["pattern"], re.I), rule["subject"]))

    def subject_for(self, title: Title) -> str | None:
        # Notes are left out: publisher names such as "Program Design" mislead the rules.
        text = " ".join([title.title, title.folder.replace("_", " ")])
        for pattern, subject in self.rules:
            if pattern.search(text):
                return subject
        return None


def title_id(title: Title) -> str:
    """Readable and stable: folder + title words, plus the split-release suffix if any."""
    variant = title.key.partition("~")[2]
    slug = re.sub(r"[^a-z0-9]+", "-", f"{title.folder} {title.title} {variant}".lower()).strip("-")
    return slug or "title"


def apply_grouping_overrides(images: list[DiskImage], overrides: dict) -> list[DiskImage]:
    excluded = set(overrides.get("exclude", []))
    placements = overrides.get("assign", {})
    kept = []
    for image in images:
        if image.path in excluded:
            continue
        placement = placements.get(image.path)
        if placement:
            image.title = placement.get("title", image.title)
            image.key = normalize_key(image.title)
            image.disk = int(placement.get("disk", image.disk))
            image.side = SIDE_NAMES.index(placement.get("side", SIDE_NAMES[image.side]).upper())
            image.support = False
        kept.append(image)
    return kept


def menu_title(title: Title) -> str:
    """Split releases share a name, so the menu shows what tells them apart."""
    if "~" not in title.key or title.key.endswith("~support"):
        return title.title
    distinguisher = ", ".join(title.notes) or title.images[0].stem
    return f"{title.title} ({distinguisher})" if distinguisher != title.title else f"{title.title} ({title.images[0].path})"


def title_record(title: Title, rules: SubjectRules, subject_overrides: dict, compat: dict) -> dict:
    identifier = title_id(title)
    override = subject_overrides.get(identifier, {})
    subject = override.get("subject", rules.subject_for(title))
    if subject is not None and subject not in SUBJECTS:
        raise ValueError(f"unknown subject {subject!r} in subject_overrides.json for {identifier}")
    hint = requirement_hint(title)
    boot_result = compat.get(title.images[0].sha256, {})
    swept = boot_result.get("requirement")
    # A sweep that could not decide says less than a "(no boot)" or "128K" in the file name.
    if swept == REQUIREMENT_UNKNOWN and hint != REQUIREMENT_UNKNOWN:
        swept = None
    requirement = override.get("requirement") or swept or hint
    source = "override" if "requirement" in override else "sweep" if swept else "filename"
    disks: dict[int, dict] = {}
    for image in title.images:
        disk = disks.setdefault(image.disk, {"number": image.disk, "label": image.label, "sides": []})
        disk["sides"].append({"side": SIDE_NAMES[image.side], "path": image.path,
                              "sha256": image.sha256, "file": image.stem})
    ordered_paths = [i.path for i in title.images]
    return {
        "id": identifier,
        "title": override.get("title", menu_title(title)),
        "subject": subject,
        # A title with no subject has no menu to go in until one is assigned.
        "hidden": bool(override.get("hidden", subject is None)),
        "folder": title.folder,
        "notes": title.notes,
        "requirement": requirement,
        "requirementSource": source,
        "requirementDetail": boot_result.get("detail", ""),
        "disks": [disks[n] for n in sorted(disks)],
        "boot": {"drive1": ordered_paths[0], "drive2": ordered_paths[1] if len(ordered_paths) > 1 else None},
        "review": title.review,
    }


def write_reviews(review_dir: str, records: list[dict]) -> None:
    os.makedirs(review_dir, exist_ok=True)
    grouping = [r for r in records if r["review"]]
    with open(os.path.join(review_dir, "grouping-review.md"), "w") as handle:
        handle.write(f"# Grouping review ({len(grouping)} titles)\n\n"
                     "Fix with `library/grouping_overrides.json` (`assign` or `exclude`), then rebuild.\n\n")
        for record in grouping:
            files = ", ".join(f"`{s['path']}`" for d in record["disks"] for s in d["sides"])
            handle.write(f"- **{record['title']}** (`{record['id']}`): {'; '.join(record['review'])}. Files: {files}\n")
    unassigned = [r for r in records if r["subject"] is None]
    with open(os.path.join(review_dir, "subject-review.md"), "w") as handle:
        handle.write(f"# Subject review ({len(unassigned)} titles with no subject; hidden from menus)\n\n"
                     "Add `\"<id>\": {\"subject\": \"Math\"}` to `library/subject_overrides.json`, then rebuild.\n\n")
        for record in unassigned:
            handle.write(f"- `{record['id']}`: {record['title']} ({record['folder'] or 'root'})\n")


def build(library_dir: str, rules_dir: str) -> dict:
    manifest = load_json(os.path.join(library_dir, "manifest.json"), None)
    if not isinstance(manifest, dict) or "files" not in manifest:
        raise ValueError(f"{library_dir}/manifest.json is missing or not a download manifest")
    rules = SubjectRules(load_json(os.path.join(rules_dir, "subject_rules.json"), []))
    subject_overrides = load_json(os.path.join(rules_dir, "subject_overrides.json"), {})
    grouping_overrides = load_json(os.path.join(rules_dir, "grouping_overrides.json"), {})
    compat = load_json(os.path.join(library_dir, "compat.json"), {}).get("results", {})

    images = [parse_image(e["path"], e["sha256"]) for e in manifest["files"]]
    images = apply_grouping_overrides(images, grouping_overrides)
    titles = group_images(images)
    records = sorted((title_record(t, rules, subject_overrides, compat) for t in titles),
                     key=lambda r: (r["subject"] or "~", r["title"].lower()))
    seen_ids: dict[str, int] = {}
    for record in records:
        count = seen_ids.get(record["id"], 0)
        seen_ids[record["id"]] = count + 1
        if count:
            record["id"] = f"{record['id']}-{count + 1}"

    rules_digest = hashlib.sha256()
    for name in ("subject_rules.json", "subject_overrides.json", "grouping_overrides.json"):
        path = os.path.join(rules_dir, name)
        if os.path.isfile(path):
            rules_digest.update(open(path, "rb").read())
    content_digest = hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()
    return {
        "schemaVersion": SCHEMA_VERSION,
        "dataRevision": content_digest[:12],
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "manifestFiles": len(manifest["files"]),
        "rulesSha256": rules_digest.hexdigest(),
        "subjects": SUBJECTS,
        "titles": records,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    library_dir, rules_dir = argv
    try:
        catalog = build(library_dir, rules_dir)
    except (OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    temporary = os.path.join(library_dir, "library.json.tmp")
    with open(temporary, "w") as handle:
        json.dump(catalog, handle, indent=1)
    os.replace(temporary, os.path.join(library_dir, "library.json"))
    write_reviews(os.path.join(library_dir, "review"), catalog["titles"])
    titles = catalog["titles"]
    placed = sum(len(s) for t in titles for s in (d["sides"] for d in t["disks"]))
    print(f"titles: {len(titles)}; images placed: {placed} of {catalog['manifestFiles']}; "
          f"with subject: {sum(1 for t in titles if t['subject'])}; "
          f"needing grouping review: {sum(1 for t in titles if t['review'])}")
    for subject in SUBJECTS + [None]:
        print(f"    {subject or '(none)':15} {sum(1 for t in titles if t['subject'] == subject)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
