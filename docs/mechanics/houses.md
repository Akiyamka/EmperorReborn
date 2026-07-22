# Emperor: Battle for Dune Mechanics — 2. Houses and sub-houses

This section establishes the **faction vocabulary** referenced by all subsequent documents
in the series. As before: logic is here; numbers are in `Rules.txt`.

**Labels:**
- `[Rules]` — parameterized in `Rules.txt`;
- `[→ N]` — details in section N of the series.

Status: **verified**.

---

## 1. Faction system structure

Two tiers:

| Tier | Who | Role |
|------|-----|------|
| **Great Houses** | Atreides, Harkonnen, Ordos | playable faction: full tech tree, buildings, roster, superweapon |
| **Sub-houses** | Fremen, Sardaukar, Ix, Tleilaxu, Guild | allied “add-on”: one building plus a few units added to the selected House's roster |

The player always plays exactly **one Great House**; sub-houses are not independently
playable—they only attach to a House.

### 1.1 How sub-houses are acquired

- **Skirmish/multiplayer**: selected during match setup, up to **two** sub-houses
  simultaneously;
- **Campaign**: alliances are offered over the course of the story; the available sub-houses
  result from player decisions on the strategic map `[→ 9]`.

### 1.2 How a sub-house is integrated into the game

- Every sub-house has exactly **one building**. If a sub-house is available to the player,
  its building appears in the construction menu alongside the House's buildings;
- after the sub-house building is constructed, **that sub-house's units** become available,
  and they are produced **from that building** (rather than from the House barracks/factory);
- aside from units, a sub-house **provides nothing**: no upgrades or abilities.

### 1.3 Availability as a flag system (important for architecture)

Two observed facts define the availability model:

1. **The entire tech tree grows from the MCV/construction yard.** Capturing an enemy construction
   yard opens potential access to the other House's entire tree—there is no “faction
   incompatibility.”
2. **Sub-house availability is bound strictly to the player.** An enemy sub-house building can be
   captured (and used), but a sub-house not selected/unlocked for that player cannot be *built*.

This yields the technical model: **the entire catalog of units and buildings is potentially
available to every player**, but parts of it are hidden by three independent filters:

- story-map settings (mission script restrictions);
- unmet tech-tree conditions (prerequisites `[Rules]`);
- sub-house flags (unlocked in the story or selected in skirmish).

Great-House building variants listed in `[BuildingGroupTypes]` share one construction-menu
slot: the source comment defines the group as a way to stop duplicate icons. When several
Construction Yards expose equivalent variants (windtraps, outposts, refineries, starports,
walls, and helipads), the native House visual is preferred; the variants remain functionally
interchangeable. House-specific buildings outside a group keep separate slots.

Faction ownership is not a “player type,” but an initial set of flags.

---

## 2. Great Houses

The Houses are **almost** structurally symmetrical: they share the same set of *functional slots*
(construction yard, refineries, barracks, factory, hangar, turrets, palace…), filled by their own
buildings/units. A known exception: **the Ordos have no aircraft reloading pad**—their air units
carry no charges, so there is nothing to reload (see §2.3). The Ordos nevertheless have a hangar,
like everyone else (it also builds carryalls; see section 3).

The game's asymmetry lies in how the slots are filled and in philosophy: each House is designed
so that its strength comes with an inherent cost.

### 2.1 Atreides — “build it and forget it” defense

- **Strength**: layered defense that functions without micromanagement—heavy artillery,
  Kindjals, snipers, and repair vehicles. A built defensive line then “works on its own”;
- **Weakness**: mobility. They can be caught while moving, on the flanks, by early attacks
  before their defense is established, and by small groups infiltrating the rear;
- **Aircraft**: weak, suitable only for supporting small breakthroughs;
- **Superweapon**: the most “useless”—it forces enemy units to retreat off the map and may deal
  no damage at all (units behind walls, too slow, map too large) `[→ 8]`;
- **Design logic**: everything is arranged so they cannot simply turtle—Atreides still have to
  attack while overcoming their weak points.

### 2.2 Harkonnen — the best defense is offense

- **Strength**: offense—speed, lethality, and good armor. They are fairly mobile;
- **Weakness**: defense and holding territory. They have almost no units that can “independently”
  hold a line: tanks and flamethrowers are short-sighted; catapults have long range, but their
  projectiles take too long to hit a moving target; missile launchers deal tremendous damage,
  but to one target and with a long reload. Units **do not repair or regenerate**—accumulated
  damage is irreversible;
- **Artillery**: the weakest of the three Houses;
- **Aircraft**: enormous damage but comically slow—useful only for offense;
- **Superweapon**: essentially a nuclear strike with radioactive contamination—also an offensive
  tool, of little use for defense `[→ 8]`.

### 2.3 Ordos — hit and run

- **Strength**: speed, maneuverability, and **rapid unit regeneration**. Deception tools:
  units that temporarily “steal” enemy vehicles (Deviator) `[→ 7]`;
- **Weakness**: direct confrontation—they lose head-on against both Houses;
- **“Aircraft”** without ammunition (and therefore without an aircraft reloading pad)—two
  unconventional units:
  - an **air mine**—compensation for the absence of static anti-air defenses;
  - an **unarmed, slow aircraft** that self-destructs, scattering bombs and deploying suicide
    troops. A group of these units that slips unnoticed into an undefended base can destroy the
    entire base;
- **Design logic**: win not head-on, but through tempo, evasion, and sabotage.

---

## 3. Sub-houses

The general pattern is that sub-house units are not “another tank,” but **carriers of unique
mechanics** absent from the base rosters. All rosters are verified; detailed behavior is `[→ 7]`.

### 3.1 Fremen — invisible ambushes

Two infantry units: one against infantry and the other against vehicles, **both invisible**
outside of attacks. Ideal for ambushes, but requiring manual control. They have low worm
“tastiness” (see section 1 §4.4).

### 3.2 Sardaukar — elite all-purpose infantry

- **Sardaukar**: against infantry, but also performs well against vehicles;
- **Elite Sardaukar**: deadly against vehicles, cuts down infantry in close combat, and also
  attacks **aircraft**.

### 3.3 Ix — illusions and sabotage

- **Infiltrator**: an invisible bomb on wheels;
- **Projector**: creates **free copies** of units. The copies gradually lose health, “burst”
  from any damage or even contact, but **deal real damage** and are indistinguishable from
  genuine units to the enemy.

### 3.4 Tleilaxu — biological weapons

- **Contaminator**: infects infantry, turning them into new Contaminators;
- **Leech**: its attack **infects vehicles** with a health-draining effect; a vehicle that
  **dies with the effect** (from any cause) **spawns another Leech**.

### 3.5 Guild — spatial tricks

- **NIAB Tank**: teleportation;
- **Maker**: very slow, deals **AoE to infantry**, very expensive, and **completely ignored
  by worms**.

### 3.6 Sub-houses in the campaign

In the story campaign, sub-houses have more units and buildings (for example, turrets and
long-range guns), but they add no fundamentally new mechanics—this expands the selection
within the same rules.

---

## 4. Architectural implications

1. **Availability = flags, not types.** A shared catalog of units/buildings exists for everyone;
   the player sees a filtered slice of it through three filters: map script, tech-tree
   prerequisites, and sub-house flags (§1.3). Capturing buildings fits this model naturally:
   a building produces what it can produce regardless of its owner's “native” House.
2. **Slot symmetry with exceptions.** Building archetypes (`refinery`, `barracks`…)
   with faction-specific variations work, but the model must allow an **empty slot**
   (the Ordos aircraft reloading pad)—symmetry is not rigid.
3. **Unique mechanics are unit properties**, not faction properties: infection, teleportation,
   holograms, and deviation are all behavior of specific units; the faction only determines
   availability.
4. **A sub-house building = an ordinary production building** with its own unit list;
   its only special feature is its construction condition (the player's sub-house flag).
