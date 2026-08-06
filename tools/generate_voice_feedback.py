#!/usr/bin/env python3
"""Convert original unit feedback SFX sections to Godot resources."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets/raw_original_content/SFX"
WAV_DIR = ROOT / "assets/converted/audio/sfx"
EVENT_DIR = ROOT / "resources/audio/events"
PROFILE_DIR = ROOT / "resources/audio/voices"
MANIFEST_PATH = ROOT / "resources/audio/generated_voice_manifest.gd"
# Every section that resolves to at least one converted WAV, in one generated
# dictionary. Model-authored FX events (XBF event type 9) name their sound by
# section, and those names are only known at runtime from the baked model meta,
# so unlike the voice/death hooks above they cannot be resolved into per-unit
# resources at convert time.
SFX_MANIFEST_PATH = ROOT / "resources/audio/generated_sfx_manifest.gd"
# Sfx.txt's [GlobalDefaults] block, applied to sections that declare none of
# their own. Only the new SFX manifest honours it; the voice/death resources
# keep the values they were generated with.
GLOBAL_DEFAULT_CONTROLS = ["random"]
GLOBAL_DEFAULT_VOLUME = 80
GLOBAL_DEFAULT_LIMIT = 5
GLOBAL_DEFAULT_PRIORITY = "normal"
UNIT_DIR = ROOT / "resources/units/definitions"
VOICE_SUFFIXES = ("Selection", "Move", "Attack")
# Death/explosion hooks: 21 distinct `*dying*` sections (grep-confirmed across
# every assets/raw_original_content/SFX/*.txt file, mostly per-unit/per-house,
# e.g. [SardaukarDying], [atnormalmandying], [HKDICEDMANDYING]) plus a fixed
# set of category hooks that do not end in "Dying" at all.
DEATH_SUFFIXES = ("Dying",)
DEATH_EVENT_IDS = {
    # "explode" is HarkDevastatorDie, not a generic explosion — like
    # hkmedium1/hkmedium2/hksmall1 it is a per-vehicle personal death hook
    # renamed away from a label that survives only as a commented-out line
    # above the section. small/medium/large are the genuinely generic,
    # size-tiered vehicle family. See docs/quirks.md.
    "explode", "hkmedium1", "hkmedium2", "hksmall1",
    "small", "medium", "large",
    "burningsmall", "burninglarge",
    "choking", "contamchoking", "atchoking", "hkchoking", "orchoking",
    # The crush family: infantry models fire these off their "Run Over 1" clip
    # (XBF FX event type 9, see scripts/units/authored_death_voice.gd). All four
    # sections play the same crush_guy_1..4 pool and none of them ends in
    # "Dying", so DEATH_SUFFIXES never picked them up.
    "crush", "atcrush", "hkcrush", "orcrush",
}
# ImportedSfx.txt redefines a number of already-defined sections with a single
# localized ($-prefixed) sample name that was never converted, and the merge
# below is last-file-wins, so such a redefinition normally wipes out the real
# English definition (docs/quirks.md). For most ids that is harmless — the
# event drops out of DEATH_EVENT_PATHS and the runtime falls through to a
# generic hook. The ids below have no fallback worth taking:
#
# - hkmedium1/hkmedium2/hksmall1 are per-vehicle personal death hooks
#   (HarkAssaultTankDie / HarkInkvineDie / HarkBuzzsawDie), so losing them means
#   losing the sound outright.
# - The Atreides/Harkonnen infantry hooks are named directly by the FX event
#   tables baked into every AT/HK infantry model, which is now what picks the
#   death voice (scripts/units/authored_death_voice.gd). They carry an
#   `FShift` the generic sections do not, and keeping them means the resolver
#   plays the section the artists actually named instead of falling back. Their
#   Ordos counterparts need no entry here: ORDOSSFX.TXT sorts after
#   ImportedSfx.txt, so last-file-wins already keeps the real definition.
SHADOW_PROOF_EVENT_IDS = {
    "hkmedium1", "hkmedium2", "hksmall1",
    "atnormalmandying", "hknormalmandying",
    "atburningmandying", "hkburningmandying",
    "atchoking", "hkchoking",
    "atcrush", "hkcrush",
}
SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:;.*)?$")
PROPERTY_RE = re.compile(r"^\s*([^=;]+?)\s*=\s*(.*?)\s*$")
UNIT_ID_RE = re.compile(r'^config_id = &"([^"]+)"$', re.MULTILINE)


@dataclass
class Event:
    event_id: str
    event_type: str = ""
    controls: list[str] = field(default_factory=list)
    samples: list[tuple[str, bool]] = field(default_factory=list)
    volume: int = 100
    priority: str = ""
    limit: int = 0
    attack_count: int = 0
    decay_count: int = 0
    # Which of the above the section spelled out itself. Only the SFX manifest
    # reads these, to know where to substitute Sfx.txt's [GlobalDefaults].
    volume_declared: bool = False
    limit_declared: bool = False
    priority_declared: bool = False


def godot_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def string_name(value: str) -> str:
    return "&" + godot_string(value)


def string_array(values: list[str]) -> str:
    return "[" + ", ".join(godot_string(value) for value in values) + "]"


def name_array(values: list[str]) -> str:
    return "[" + ", ".join(string_name(value) for value in values) + "]"


def bool_array(values: list[bool]) -> str:
    return "[" + ", ".join("true" if value else "false" for value in values) + "]"


def resource_text(script_class: str, script_path: str, properties: list[str]) -> str:
    return "\n".join([
        f'[gd_resource type="Resource" script_class="{script_class}" load_steps=2 format=3]',
        "",
        f'[ext_resource type="Script" path="{script_path}" id="1_definition"]',
        "",
        "[resource]",
        'script = ExtResource("1_definition")',
        *properties,
        "",
    ])


def strip_comment(value: str) -> str:
    quoted = False
    for index, char in enumerate(value):
        if char == '"':
            quoted = not quoted
        elif char == ";" and not quoted:
            return value[:index].strip()
    return value.strip()


def parse_int(value: str, default: int) -> int:
    try:
        return int(float(value))
    except ValueError:
        return default


def parse_sources() -> dict[str, Event]:
    events: dict[str, Event] = {}
    for path in sorted(SOURCE_DIR.iterdir(), key=lambda item: item.name.casefold()):
        if path.suffix.casefold() != ".txt" or path.name.casefold() == "sfx.txt":
            continue
        defaults: dict[str, str] = {}
        current: Event | None = None
        for raw_line in path.read_text(encoding="cp1252").splitlines():
            if raw_line.lstrip().startswith(";"):
                continue
            section = SECTION_RE.match(raw_line)
            if section:
                section_name = section.group(1).strip()
                if section_name.casefold() == "localdefaults":
                    current = None
                    defaults = {}
                elif section_name.casefold() in SHADOW_PROOF_EVENT_IDS and section_name.casefold() in events:
                    # Parse the redefinition into a throwaway Event so its
                    # properties don't leak onto the kept one, but leave the
                    # earlier, real definition in `events`.
                    current = Event(section_name)
                else:
                    current = Event(
                        section_name,
                        event_type=defaults.get("type", ""),
                        controls=defaults.get("control", "").casefold().split(),
                    )
                    events[section_name.casefold()] = current
                continue
            prop = PROPERTY_RE.match(raw_line)
            if prop is None:
                continue
            key = prop.group(1).strip().casefold()
            value = strip_comment(prop.group(2))
            if current is None:
                if key in {"type", "control"}:
                    defaults[key] = value
                continue
            if key == "sounds":
                for token in re.findall(r'"[^"]*"|\S+', value):
                    sample = token.strip('"')
                    if sample:
                        localized = sample.startswith("$")
                        current.samples.append((sample.lstrip("$"), localized))
            elif key == "type":
                current.event_type = value
            elif key == "control":
                current.controls = value.casefold().split()
            elif key == "volume":
                current.volume = parse_int(value, 100)
                current.volume_declared = True
            elif key == "priority":
                current.priority = value.casefold()
                current.priority_declared = True
            elif key == "limit":
                current.limit = parse_int(value, 0)
                current.limit_declared = True
            elif key == "attack":
                current.attack_count = parse_int(value, 0)
            elif key == "decay":
                current.decay_count = parse_int(value, 0)
    return events


def voice_events(events: dict[str, Event]) -> dict[str, Event]:
    return {
        event.event_id: event
        for event in events.values()
        if event.samples and voice_suffix(event.event_id)
    }


def voice_suffix(event_id: str) -> str:
    folded = event_id.casefold()
    return next(
        (suffix for suffix in VOICE_SUFFIXES if folded.endswith(suffix.casefold())),
        "",
    )


def death_events(events: dict[str, Event]) -> dict[str, Event]:
    return {
        event.event_id: event
        for event in events.values()
        if event.samples and is_death_event(event.event_id)
    }


def is_death_event(event_id: str) -> bool:
    folded = event_id.casefold()
    if folded in DEATH_EVENT_IDS:
        return True
    return any(folded.endswith(suffix.casefold()) for suffix in DEATH_SUFFIXES)


def wav_lookup() -> dict[str, Path]:
    return {path.stem.casefold(): path for path in WAV_DIR.glob("*.wav")}


def event_text(event: Event, wavs: dict[str, Path]) -> tuple[str, list[str]]:
    paths: list[str] = []
    localized: list[bool] = []
    missing: list[str] = []
    for sample, is_localized in event.samples:
        wav = wavs.get(sample.casefold())
        if wav is None:
            missing.append(sample)
            continue
        paths.append("res://" + wav.relative_to(ROOT).as_posix())
        localized.append(is_localized)
    return resource_text("SoundEvent", "res://scripts/audio/sound_event.gd", [
        f"event_id = {string_name(event.event_id)}",
        f"event_type = {string_name(event.event_type)}",
        f"controls = {name_array(event.controls)}",
        f"sample_paths = {string_array(paths)}",
        f"localized_samples = {bool_array(localized)}",
        f"volume = {event.volume}",
        f"priority = {string_name(event.priority)}",
        f"limit = {event.limit}",
        f"attack_count = {event.attack_count}",
        f"decay_count = {event.decay_count}",
    ]), missing


def event_path(event_id: str) -> str:
    return "res://" + (EVENT_DIR / f"{event_id}.tres").relative_to(ROOT).as_posix()


def canonical_unit_ids() -> dict[str, str]:
    result: dict[str, str] = {}
    for path in UNIT_DIR.glob("*.tres"):
        match = UNIT_ID_RE.search(path.read_text(encoding="utf-8"))
        if match:
            result[match.group(1).casefold()] = match.group(1)
    return result


def profile_text(profile_id: str, hooks: dict[str, str]) -> str:
    return resource_text("UnitVoiceProfile", "res://scripts/audio/unit_voice_profile.gd", [
        f"profile_id = {string_name(profile_id)}",
        f"selection_event_path = {godot_string(hooks.get('Selection', ''))}",
        f"move_event_path = {godot_string(hooks.get('Move', ''))}",
        f"attack_event_path = {godot_string(hooks.get('Attack', ''))}",
    ])


def manifest_text(profile_paths: dict[str, str], death_event_paths: dict[str, str]) -> str:
    lines = [
        "# Generated by tools/generate_voice_feedback.py; do not hand-edit.",
        "extends RefCounted",
        "",
        "const PROFILE_PATHS: Dictionary = {",
    ]
    lines.extend(
        f"\t{string_name(profile_id)}: {godot_string(profile_paths[profile_id])},"
        for profile_id in sorted(profile_paths)
    )
    lines.extend([
        "}",
        "",
        # Keyed by the death/explosion sound-event id casefolded, since the
        # composing death strategies always produce lowercase ids
        # (e.g. &"atburningmandying") while the surviving section's own
        # casing depends on which source file last defined it (parse_sources()
        # keys by section_name.casefold() and is last-file-wins).
        "const DEATH_EVENT_PATHS: Dictionary = {",
    ])
    lines.extend(
        f"\t{string_name(event_id)}: {godot_string(death_event_paths[event_id])},"
        for event_id in sorted(death_event_paths)
    )
    lines.extend(["}", ""])
    return "\n".join(lines)


def sfx_sections(events: dict[str, Event], wavs: dict[str, Path]) -> dict[str, dict]:
    """Every parsed section that resolves to at least one converted WAV.

    Sections whose samples are all localized ($-prefixed) stubs that never made
    it into the archive resolve to nothing and are omitted, so a caller asking
    for such a name gets "unknown section" rather than a silent one.
    """
    result: dict[str, dict] = {}
    for event in events.values():
        paths = [
            "res://" + wavs[sample.casefold()].relative_to(ROOT).as_posix()
            for sample, _localized in event.samples
            if sample.casefold() in wavs
        ]
        if not paths:
            continue
        result[event.event_id.casefold()] = {
            "id": event.event_id,
            "paths": paths,
            "controls": event.controls if event.controls else GLOBAL_DEFAULT_CONTROLS,
            "volume": event.volume if event.volume_declared else GLOBAL_DEFAULT_VOLUME,
            "limit": event.limit if event.limit_declared else GLOBAL_DEFAULT_LIMIT,
            "priority": event.priority if event.priority_declared else GLOBAL_DEFAULT_PRIORITY,
        }
    return result


def sfx_manifest_text(sections: dict[str, dict]) -> str:
    lines = [
        "# Generated by tools/generate_voice_feedback.py; do not hand-edit.",
        "extends RefCounted",
        "",
        "# Original SFX sound-event sections, keyed by section name casefolded:",
        "# model-authored FX events (XBF event type 9) name their section in the",
        "# baked model meta, so the lookup happens at runtime. Sections that",
        "# resolve to no converted WAV are absent, never present-but-empty.",
        "# Volume/Limit/Control fall back to Sfx.txt's [GlobalDefaults].",
        "const SECTIONS: Dictionary = {",
    ]
    for section_id in sorted(sections):
        entry = sections[section_id]
        lines.extend([
            f"\t{string_name(section_id)}: {{",
            f"\t\t\"id\": {string_name(entry['id'])},",
            f"\t\t\"paths\": {string_array(entry['paths'])},",
            f"\t\t\"controls\": {name_array(entry['controls'])},",
            f"\t\t\"volume\": {entry['volume']},",
            f"\t\t\"limit\": {entry['limit']},",
            f"\t\t\"priority\": {string_name(entry['priority'])},",
            "\t},",
        ])
    lines.extend(["}", ""])
    return "\n".join(lines)


def write_or_check(path: Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        return True
    if check:
        print(f"out of date: {path.relative_to(ROOT)}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def remove_stale(directory: Path, expected: set[Path]) -> None:
    if directory.exists():
        for path in directory.glob("*.tres"):
            if path not in expected:
                path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    parsed = parse_sources()
    events = voice_events(parsed)
    death = death_events(parsed)
    wavs = wav_lookup()
    expected_events: set[Path] = set()
    expected_profiles: set[Path] = set()
    missing: dict[str, list[str]] = {}
    ok = True
    for event_id, event in sorted(events.items()):
        output = EVENT_DIR / f"{event_id}.tres"
        expected_events.add(output)
        content, absent = event_text(event, wavs)
        if absent:
            missing[event_id] = absent
        ok = write_or_check(output, content, args.check) and ok

    # Death/explosion events are dropped entirely (not written, not added to
    # expected_events, not exposed via DEATH_EVENT_PATHS) when every one of
    # their referenced samples fails to resolve against the WAV archive.
    # This matters for correctness, not just tidiness: InfantryDeathStrategy's
    # candidate-list design (death-animation plan §6) depends on a per-house
    # id being *absent* from DEATH_EVENT_PATHS to fall through to the generic
    # hook. Several per-house hooks (e.g. atnormalmandying/hknormalmandying)
    # are shadowed by ImportedSfx.txt redefinitions pointing at localized
    # sample names that were never converted (docs/quirks.md), so if such an
    # event were still emitted, Unit._resolve_sound_event_id() would treat the
    # per-house id as "present" and pick a silent event instead of falling
    # back — Atreides/Harkonnen infantry (the most common death in the game)
    # would die in total silence. Dropping the id here is the convert-stage
    # fix so the runtime fallback logic works exactly as designed, with no
    # runtime special-casing for "present but empty".
    dropped_death: dict[str, list[str]] = {}
    for event_id, event in sorted(death.items()):
        content, absent = event_text(event, wavs)
        if event.samples and len(absent) == len(event.samples):
            dropped_death[event_id] = absent
            continue
        output = EVENT_DIR / f"{event_id}.tres"
        expected_events.add(output)
        if absent:
            missing[event_id] = absent
        ok = write_or_check(output, content, args.check) and ok

    death_event_paths: dict[str, str] = {
        event_id.casefold(): event_path(event_id)
        for event_id in death
        if event_id not in dropped_death
    }

    by_profile: dict[str, dict[str, str]] = {}
    known_units = canonical_unit_ids()
    for event_id in events:
        suffix = voice_suffix(event_id)
        source_profile_id = event_id[:-len(suffix)]
        profile_id = known_units.get(source_profile_id.casefold(), source_profile_id)
        by_profile.setdefault(profile_id, {})[suffix] = event_path(event_id)
    profile_paths: dict[str, str] = {}
    for profile_id, hooks in sorted(by_profile.items()):
        output = PROFILE_DIR / f"{profile_id}.tres"
        expected_profiles.add(output)
        profile_paths[profile_id] = "res://" + output.relative_to(ROOT).as_posix()
        ok = write_or_check(output, profile_text(profile_id, hooks), args.check) and ok
    ok = write_or_check(MANIFEST_PATH, manifest_text(profile_paths, death_event_paths), args.check) and ok
    sections = sfx_sections(parsed, wavs)
    ok = write_or_check(SFX_MANIFEST_PATH, sfx_manifest_text(sections), args.check) and ok

    if not args.check:
        remove_stale(EVENT_DIR, expected_events)
        remove_stale(PROFILE_DIR, expected_profiles)
        print(
            f"generated {len(events)} voice events, {len(death) - len(dropped_death)} "
            f"death/explosion events, {len(by_profile)} voice profiles and "
            f"{len(sections)} SFX sections"
        )
    if missing:
        count = sum(len(samples) for samples in missing.values())
        print(f"warning: {count} referenced samples are absent from the WAV archive (event kept, some samples missing)")
        for event_id, samples in sorted(missing.items()):
            print(f"  {event_id}: {', '.join(samples)}")
    if dropped_death:
        count = sum(len(samples) for samples in dropped_death.values())
        print(
            f"warning: {len(dropped_death)} death/explosion events dropped entirely "
            f"({count} referenced samples all absent from the WAV archive; event not written, "
            "not in DEATH_EVENT_PATHS)"
        )
        for event_id, samples in sorted(dropped_death.items()):
            print(f"  {event_id}: {', '.join(samples)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
