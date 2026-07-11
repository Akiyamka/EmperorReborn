# Emperor: Battle for Dune Mechanics — 5. Units

This section describes **unit logic**: movement classes, general ground-unit
rules, aircraft, transport, veterancy, and a catalog of unique ability mechanics.
Combat calculations (damage, armor, hits) are in section 6; this section covers
only *what a unit can do*, not *how much damage it deals*.

**Labels:**
- `[?]` — requires verification;
- `[Rules]` — parameterized in `Rules.txt`;
- `[design]` — intentional deviation in our implementation;
- `[→ N]` — details in section N of the series.

Status: **verified**.

---

## 1. Movement classes

Passability is determined by the pair “unit movement class × surface type”
(the matrix from section 1 §1):

| Class | Applies to | sand | rock | dustbowl | infantryrock | ramp | cliff |
|-------|------------|------|------|----------|--------------|------|-------|
| **infantry** | all infantry | ✔ | ✔ | ✘ | ✔ | ✔ | ✘ |
| **ground vehicle** | wheeled/tracked vehicles | ✔ | ✔ | ✘ | ✘ | ✔ | ✘ |
| **hover** | Ordos hovering vehicles | ✔ | ✔ | ✔ | ✘ | ✔ | ✘ |
| **dust scout** | Dust Scout only | ✔ | ✔ | ✔ + submersion | ✘ | ✔ | ✘ |
| **air** | aircraft, carryall | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |

The open questions about the matrix are resolved (verified): **hovers and the
Dust Scout cannot enter infantry rock** (marked ✘ in the table); **speed does
not depend on surface type**.

Movement modifiers and class properties (verified):

- **Suppression** (verified): under incoming damage, a unit is slowed both in
  **movement** and **attack speed**. Which units are **susceptible** to
  suppression and which **can suppress** are described as per-flag settings in
  `Rules.txt` `[Rules]` (the same two-flag model as crushing — §2). This is the
  only speed modifier; surface does not affect speed;
- **hovers** can **turn and move simultaneously** (ordinary vehicles cannot:
  hull turning and movement are separate);
- **worms hunt everything on sand** (section 1 §4), including hovers: the
  movement class **does not affect** attraction — hovers attract worms just as
  much as tracked vehicles (a balance decision, not “physics”);
- air units and units on rock/infantry rock are unreachable by worms.

---

## 2. General ground-unit rules

- **Crushing** (verified): determined by **two per-unit flags in `Rules.txt`** —
  “can crush” (crusher) and “can be crushed” (crushable). The engine checks the
  flag pair; there is no built-in weight-class logic. The observed behavior
  (all vehicles except light ones crush; hovers do not crush; all infantry is
  crushable, including Sardaukar) comes from **flag values** in the rules, not
  an engine rule. There is no evasion. The sole protection is infantry rock
  (section 1 §1.1);
- units **push** each other aside: friendly units yield the way (verified; see
  also pushing during building placement — section 4 §2);
- **encounters with worms, tornadoes, and blooms** follow the rules in section 1;
- **orders** (verified): move / attack / attack-move / stop / guard +
  **formation movement** — under a group order, every unit in the group moves
  at the speed of the **slowest** member;
- **behavior stances** (verified) — two: **defensive** and **passive**. In the
  passive stance, a unit **does not initiate attacks** on its own — it only
  responds to damage, and only if the attacker is within range. The passive
  stance is **enabled by default for stealth units** (so they do not reveal
  themselves by attacking autonomously — attacking removes invisibility, §7.0.1).

---

## 3. Aircraft

Aircraft are not homogeneous — the “sortie → ammunition expenditure → reload”
loop applies **only to two combat planes**: one Harkonnen and one Ordos plane
(verified; the specific units, as well as the full House-by-House aircraft roster,
are described in `Rules.txt` `[Rules]`).

**Ammunition loop** (verified):

- a plane has **limited ammunition** `[Rules]`; it lands at a **landing pad** —
  a separate building — to replenish it;
- a plane can also land **on the ground** — but without replenishing ammunition;
- **on the ground (including on a pad), a plane counts as a ground unit**:
  ground weapons can hit it, and it **cannot fire from the ground**;
- **fallback**: if no pads remain, it flies to the main base (verified,
  section 4 §1).

**Orbits**: armed combat planes do not orbit. Some other air units do orbit —
**carryalls** and the **ATADP** (the Atreides anti-aircraft plane); their orbits
may carry them beyond the map boundary, but players cannot order them there
(section 1 §5).

Other points:

- aircraft are unreachable by ground weapons without anti-air capability
  `[→ 6]` (except while “on the ground” — see above);
- worms cannot reach aircraft; **tornadoes can**: aircraft inside a tornado
  area take damage (verified; see section 1 §6);
- **one pad services one plane at a time** (verified); if there are fewer pads
  than planes, the planes **rotate automatically**, taking turns using a pad
  to replenish ammunition;
- the **House-by-House air-unit roster is `Rules.txt` data** `[Rules]` and is
  not duplicated here (by the series rule: the document describes logic, not
  catalogs).

---

## 4. Transport

### 4.1 Carryall

Two tiers (verified):

- **regular carryall — automatic harvester logistics**: automatically picks up
  a harvester and carries it between the field and refinery (the economic loop —
  section 3); the assigned carryall is the **nearest available** one; a picked-up
  harvester is saved from a worm (section 1 §4.3d);
- **advanced carryall — manual control**: the player issues orders directly;
  carries **one vehicle unit** at a time;
  - **can also lift enemy vehicles** — with a **lift-time penalty** `[Rules]`.
    Thus, an advanced carryall is also a tool for “abducting” enemy units (for
    example, lifting an enemy harvester directly from the field);
- **vulnerability** (verified): when a carryall is destroyed in flight, its
  carried unit **dies with it**; the carried unit is nevertheless a **separate
  target** and can be destroyed independently of its carrier.

### 4.2 Infantry transport

- Available to **Atreides and Ordos** (verified); Harkonnen has none. Specific
  units and capacity are `[Rules]`;
- unloads on command; **if the transport is destroyed, its passengers die with
  it** (verified) — the rule is shared with the carryall: cargo shares the
  carrier's fate.

---

## 5. Veterancy

- Units gain **experience from kills** and advance in ranks (verified);
- **experience economy** (verified): every unit has its own experience **“cost”**
  `[Rules]`, which works in both directions:
  - the more expensive a unit is, the **more slowly it levels itself** (it needs
    more experience per rank);
  - and the **more experience its killer receives**.
  Thus, one parameter specifies both progression cost and the reward for its
  destruction;
- **rank effects** (verified): these are described **individually for each
  combat unit** in `Rules.txt` and differ between units `[Rules]` — there is no
  universal engine table of “per-rank” bonuses; this is per-unit data (possible
  effects, including self-repair where present, reside there as well);
- **non-combat units (harvester, etc.) are outside the veterancy system**
  (verified): they have no ranks even though they can kill (for example, by
  running over infantry);
- there are **at most three levels** (verified); rank is displayed as **stripes
  (chevrons) above the unit**.

---

## 6. Unit repair and recovery

Vehicle repair is **asymmetric by faction** (verified):

- **Atreides** — vehicles are repaired by **dedicated repairer units** (the
  specific unit is `[Rules]`): repair is the active work of one unit on another;
- **Ordos** — all vehicles **regenerate on their own** (passive self-repair)
  `[Rules: speed]`;
- **Harkonnen** — has **no standard vehicle repair** (verified): damage to its
  vehicles is irreversible.

A separate universal mechanic (verified): **engineers of all three Houses can
“remove a leech”** — remove the **Leech infection effect** (Tleilaxu, §7.2)
from friendly vehicles. In essence, this repairs a negative effect rather than HP.

**Infantry cannot be healed at all** (verified) — no House has medics or other
means of restoring infantry HP; lost infantry health is irrecoverable.

---

## 7. Catalog of unique mechanics

Format: unit → mechanic. Numbers are `[Rules]`. Behavioral details require verification.

### 7.0 Shared systems

Two mechanics that look like “abilities of individual units” but are in fact
system-wide primitives configured per unit.

#### 7.0.1 Stealth (verified)

Stealth is not a property of particular units but a **system-wide effect** that
can be applied to any unit: in particular, it can be **found in a crate**
(the crate mechanic is section 3 §8; invisibility is one of the “abilities” in
its loot table) or **received as a veterancy rank effect** (§5). Two invisibility
types exist:

1. **“Invisible while not moving”** — with an important softening: revealing
   does **not occur instantly** when movement starts, but after a `[Rules]`
   delay, so the unit can move in **short bursts** without revealing itself.
   Returning to stealth requires **the same time spent stationary** (the symmetry
   “reveal timer = concealment timer”). Compare the short-burst trick against
   worms — section 1 §4.1;
2. **“Invisible while not firing”** — attacking reveals the unit; units of this
   type default to the passive stance (§2).

**Detection** (verified):

- **any unit** detects an invisible unit by **approaching closely** `[Rules: radius]`;
- among buildings, **only turrets** can reveal invisible units, at short range;
- the list is exhaustive (verified): the game has no dedicated detector units,
  upgrades, or radar that reveal stealth.

**Stealth and damage** (verified): severely damaged vehicles that reach the
**burning** threshold **lose their ability to use stealth** until repaired above
the threshold — a burning vehicle cannot be hidden. (The “burning” state as a
vehicle damage stage is covered by section 6 `[→ 6]`.)

Dust Scout submersion in quicksand is **not stealth** (verified): the unit is
**physically below the surface**. In this state it is invisible, **cannot be
revealed** by any detection means, and **cannot take damage**. This is a separate
“underground” state, not an invisibility effect.

#### 7.0.2 Deploy (verified)

**“Deploy” is a single game-wide verb**: one command whose effect is specified
per unit. Known effect variants:

- **transformation into a building** — MCV → Construction Yard (section 4 §1);
- **switch to a stationary combat mode** — Kobra → artillery form (§7.1);
- **self-destruction/detonation** — Devastator (explosion with radiation),
  Saboteur / Infiltrator (detonator countdown → powerful explosion);
- **transition into a stationary state** (without transformation) — for some
  units, deploy simply fixes them in place `[Rules: which unit has which effect]`.

That is, in the implementation this is a single `deploy()` interface with a
per-unit strategy, not a collection of unrelated abilities. Units occupied with
deployment are generally vulnerable (the Saboteur deployment window — §7.1).

### 7.1 Great Houses

- **Sonic Tank (Atreides)** (verified) — a sonic wave with a unique damage model:
  - a **slow projectile** traveling in a line and **passing through everything** —
    units, buildings, and walls;
  - damage is dealt **for the entire time the trajectory intersects** a combat
    unit or building → **large targets take much more damage** (a longer
    intersection means more damage ticks). The implementation mechanism is a
    bullet spawning a chain of warheads as it moves (section 6 §3);
  - **friendly fire**: allies on the line suffer equally;
- **Kobra (Ordos)** — artillery with **deployment**: it moves in travel mode;
  when deployed, it is stationary and has greatly increased range/damage `[Rules]`;
- **Deviator (Ordos)** — a gas projectile that **temporarily converts** enemy
  vehicles `[Rules: duration]`. Effects by target type (verified):
  - **vehicles** — pass under control for the duration;
  - **infantry** — cannot be converted and is **killed immediately** by the gas;
  - **buildings** — are not converted; damage is nominal (the specific value is
    in `Rules.txt`, around one) `[Rules]`;
  - when the duration expires, vehicles **return to the owner's control**
    (verified);
- **Dust Scout (Ordos)** (verified) — a scout, the only ground unit able to walk
  on quicksand + **submerge in dustbowl**: beneath the surface it is invisible,
  **undetectable and invulnerable** (a separate “underground” state, not stealth —
  §7.0.1); it is **armed** (weapon is `[Rules]`);
- **Saboteur (Ordos)** (verified) — a walking bomb, **not stealth**. It has two
  explosion modes; it dies in both:
  - **death caused by an enemy** → a **small explosion** in place — crushing it
    with a vehicle hurts, and the killer takes splash damage;
  - **self-detonation**: the player activates the detonator — **deployment takes
    time**, and if the Saboteur is not killed before the countdown ends, the
    explosion is **much more powerful** `[Rules: both damages/radii, deploy time]`.
  Thus, enemy counterplay is to kill it *before* deployment finishes, trading
  the large explosion for a small one;
- **Devastator (Harkonnen)** (verified) — a superheavy platform with **two
  weapons** `[Rules]` and a **self-destruct** command: an explosion that damages
  the surrounding area + **residual radiation** in the area
  `[Rules: radiation damage/radius/duration]`;
- **Inkvine Catapult (Harkonnen)** (verified) — an indirect-fire projectile that
  leaves a **chemical-residue area** with two states:
  - **chemical**: residual damage to **infantry only** — chemical residue does
    not harm vehicles `[Rules: DoT]`;
  - **ignition**: the area **ignites from any AoE damage** — burning residue
    damages **vehicles as well**, infantry inside it **burns instantly**, but in
    the burning mode the area **burns out quickly** (short lifetime);
  Thus, it provides a combo mechanic: saturate with chemicals → ignite with
  splash damage — trading area duration for lethality;
- **Flame units (Harkonnen)** — flamethrower damage, strong against infantry `[→ 6]`;
- **Engineer (all Houses)** — two functions:
  - **capturing buildings** (verified): enters an enemy building (or neutral one —
    section 1 §8), immediately transferring the building to the player; the
    engineer is consumed. **Does not work on walls or turrets**; all other
    buildings are capturable;
  - **removing Leech** from friendly vehicles (verified, §6).

### 7.2 Sub-Houses

- **Fremen (Warrior / Fedaykin)** — “invisible while not firing” stealth
  (§7.0; detection follows the general rules there); interaction with worms —
  section 1 §4.4;
- **Sardaukar / Elite Sardaukar** (verified) — heavy elite infantry with **two
  weapons** `[Rules]`; not immune to crushing (§2). Note: multiple weapons on a
  unit are a system-wide capability `[Rules]`, not unique to Sardaukar
  (Devastator also has two — §7.1);
- **Contaminator (Tleilaxu)** (verified) — **infection**: infantry it kills
  **immediately** turns into a new Contaminator under the owner's control; this
  works **only on infantry** (vehicles/buildings are outside the conversion mechanic);
- **Leech (Tleilaxu)** (verified) — vehicle infector. Mechanic:
  - Leech **does not physically attach** — its attack **applies an effect** to
    the target;
  - the effect applies **only to vehicles**; against infantry, the attack merely
    deals damage without the effect;
  - the effect **slowly kills** the infected unit `[Rules: speed]`;
  - a unit that **dies with the effect active** — from any cause, not necessarily
    the effect itself — leaves a **new Leech** at its death location (under the
    Leech owner's control), so its population reproduces through victims;
  - **counter-mechanic**: an engineer of any House removes the effect from
    friendly vehicles (§6);
- **NIAB Tank (Guild)** (verified) — **teleportation** instead of driving:
  - it can teleport **only into explored territory**;
  - it has **no recharge (cooldown)** — the limiter is different: after
    teleporting, the unit is **helpless and immobile** for a time
    `[Rules: duration]` (a vulnerability window rather than a timer);
- **Maker (Guild)** (verified, section 2 §3.5) — a very slow, expensive unit
  with **AoE damage against infantry**; worms **completely ignore it** — the
  only known *true* exception to worm rules (unlike the emergent “safety” of
  Fremen — section 1 §4.4) `[Rules: flag]`;
- **Projector (Ix)** (verified) — creates **free holographic copies** of units:
  - they **deal real damage** and are **indistinguishable from real units** to
    the enemy;
  - they **burst from any damage** (or even contact);
  - they **gradually lose HP themselves** — their lifetime is limited by decay
    `[Rules: speed]`;
- **Infiltrator (Ix)** (verified) — the **invisible version of the Ordos
  Saboteur** (§7.1: the same two modes — a small explosion on death and a
  powerful one after the detonator deployment completes), with two differences:
  - **“invisible while not firing” stealth** (verified), where “firing” in its
    case means **starting the detonation countdown**: invisibility persists until
    the timer is activated;
  - it is **classified as a vehicle**, not infantry — with all consequences of
    that classification (verified): it cannot be crushed, anti-vehicle weapons
    work against it, “against vehicles” effects apply (Leech, Deviator), and it
    **can be repaired** (by an Atreides repairer, etc. — §6). None of the
    consequences are specified separately; all follow automatically from the class;

---

## 8. Open questions

None — all section questions have been resolved through verification. (The crates
that surfaced in §7.0.1 turned out to be already documented in section 3 §8.)

Accumulated forward references for section 6 “Combat” (notes, not questions):
vehicle “burning” state (§7.0.1), multiple weapons (§7.1/7.2), suppression (§1),
residual-effect areas — chemical/fire/radiation (§7.1), Sonic Tank's piercing
projectile (§7.1), indirect trajectories and the height bonus (section 1 §2),
and anti-air capability (§3).
