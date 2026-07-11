# Emperor: Battle for Dune Mechanics — 6. Combat

This section collects the combat model: how damage is calculated, how projectiles
fly, how units choose targets, and what happens to damaged units. It consolidates
notes from previous sections (listed in section 5 §8); numbers are in `Rules.txt`.

**Labels:**
- `[?]` — requires verification;
- `[Rules]` — parameterized in `Rules.txt`;
- `[← N]` — rule already verified in section N and consolidated here.

Status: **draft pending verification**.

---

## 1. Damage model: weapon × armor

- Basic scheme: a weapon has a **warhead** with a type (§2), and a target has an
  **armor type**; final damage = base damage × the **modifier for the “warhead
  type × armor” pair** from the matrix in `Rules.txt` `[Rules]` `[?]` — verify
  that the model is in fact matrix-based (percentage modifiers), rather than another model;
- the matrix expresses specializations: anti-infantry, anti-vehicle, and anti-air
  weapons are matrix rows rather than separate mechanics `[?]`;
- **zero pairs**: some combinations deal no damage at all (Inkvine chemical does
  not harm vehicles `[← 5]`; direct-fire weapons cannot reach air — §7) `[?]` —
  how zero is represented: a zero in the matrix or separate flags;
- building damage uses the same matrix (buildings have their own armor type) `[?]`.

## 2. Weapon model: turret → bullet → warhead

Weapons in `Rules.txt` are a pipeline of three entities (verified):

- **Turret** — the projectile-emission point on a unit:
  - may be **fixed** (rigidly aligned with heading — firing requires turning the
    hull) or **rotating**;
  - **turrets on turrets** are supported — nesting for aiming along different
    axes, where different model parts rotate independently (for example, the
    mount horizontally and the barrel vertically);
- **Bullet** — what exits a turret: it has its own parameters — **speed,
  trajectory**, etc. `[Rules]`. It **may be absent** — then the hit is instant
  (this answers the hitscan question: not a separate weapon type, but the
  degenerate case of “a weapon without a bullet”);
- **Warhead** — damage delivery: **type** (for the §1 matrix), **applied negative
  effects**, and the projectile's **burst visual effect**.

Consequence for §1: negative effects (suppression, Deviator gas, Leech infection,
Inkvine chemical) are **warhead properties**; that is, “damage” and “effect” are
delivered by one mechanism `[?]` — confirm that the listed effects are indeed
implemented by warheads.

Other weapon properties on a unit:

- a unit carries **one or more weapons** `[← 5: Sardaukar, Devastator]` `[Rules]`;
  selection logic when several are present: by **target type** `[?]`; can two
  weapons operate **simultaneously against different targets** `[?]`;
- reload/rate of fire is per weapon `[Rules]`; suppression slows attacks `[← 5 §1]`.

## 3. Projectiles and trajectories

Projectiles (“bullets” from §2) are **physical 3D objects** with speed and
trajectory parameters `[← 1 §1: collisions]` `[Rules]`. Trajectory behavior
(verified):

- **almost all bullets travel in an arc** — “direct vs. indirect” is not two
  types, but an **arc-height parameter**: a low arc collides with a cliff wall
  or wall (3D collision — section 1 §1), while a high arc (artillery) flies over
  obstacles `[Rules: arc parameters]`;
- **laser is the only exception**: it has **no travel speed** (an instant hit, the
  “no bullet” case from §2) and **never misses**;
- **piercing** (Sonic Tank): a slow wave passing through units/buildings/walls
  `[← 5 §7.1]`;
- **homing (missiles)**: pursue a target **until they hit or bullet lifetime
  expires**; if the target dies while a missile is in flight, the missile
  **self-destructs** (missiles do not overdamage “a corpse” or hit bystanders
  beyond the target).

Additional bullet properties (verified):

- a **bullet can spawn warheads as it travels** — rather than only one at the
  impact point. This implements the Sonic Tank wave: the “damage for intersection
  time” from section 5 §7.1 is a chain of warheads spawned by the bullet along
  its path (a large target catches more warheads from the chain);
- **range limit / lifetime**: a bullet has a maximum existence limit `[Rules]` —
  for homing bullets, it also serves as a stop to infinite pursuit;
- **homing** is a bullet property `[Rules]` with a **turn-rate limit** (verified):
  a bullet adjusts its trajectory toward the target, but no faster than its
  angular speed — a fast/maneuverable target can “dodge” a missile;
- **there is no lead targeting** (verified): units fire at the target's **current
  position**, not a calculated intercept point — a target moving sideways escapes
  non-homing bullets. Compensation is left to the player as a micro-management
  element: the **attack ground** order (§4) allows manual leading;
- **indirect-fire spread** (verified): indirect bullets land with dispersion
  around the aim point `[Rules: amount]` — artillery is inherently inaccurate
  against mobile targets.

Summary of how different bullets miss (follows from the verified behavior above):

- **non-homing arc bullets**: no lead + spread → the bullet lands at a ground
  point near the target's former position and bursts there with a warhead — splash
  may hit neighbors `[?: confirm bursting at the impact point]`;
- **missiles**: a miss means the target dodged beyond the turn-rate limit or the
  bullet outlived its lifetime; target death in flight → self-destruction;
- **laser**: never misses.

## 4. Range, elevation, visibility

- **downhill range bonus**, increasing with height difference `[← 1 §2]`;
- firing uphill is possible only with indirect fire `[← 1 §2]`;
- the **target must be visible** (by the player's scouting/vision) to issue an
  attack order `[?]`; the **attack ground** order exists (verified, §3) — firing
  at a coordinate without a target, a tool for manual leading and area fire;
- a unit's **vision** radius and **weapon** radius are independent parameters
  `[Rules]`; can a weapon outrange vision (requiring a spotter) `[?]`.

## 5. Automatic target acquisition

- In the defensive stance, a unit **opens fire itself** on enemies in range; in
  the passive stance, it only responds `[← 5 §2]`;
- auto-acquisition priorities: nearest target or weighted selection
  (threat/type) `[?]`;
- a unit **pursues** a target that leaves range when auto-acquiring `[?]` (and
  how far — leash from the guard point `[?]`);
- guard order: reaction radius and return to post `[?]`.

## 6. Damage states

- **Vehicles — “burning” threshold** `[← 5 §7.0.1]`: below an HP threshold, a
  vehicle burns (visible smoke/fire), and a burning vehicle cannot use stealth.
  Clarify `[?]`:
  - whether it burns with gradual HP loss (burns to death) or is merely a state marker;
  - whether the threshold is shared by all vehicles or per unit `[Rules]`;
- **infantry**: are there state stages (wounds) `[?]` — presumably not;
- **buildings**: visual damage stages (smoke/fire) `[?]`; do they affect
  functionality (such as slower production at low HP) `[?]`.

## 7. Anti-air capability

- The ability to hit air is a **weapon property** (AA flag or warhead) `[Rules]` `[?]`;
- air is unreachable by non-AA weapons `[← 5 §3]`, except for a landed plane
  (a ground unit `[← 5 §3]`);
- are there “air-only” weapons (unable to hit ground) `[?]`.

## 8. Residual-effect areas

Shared “area on the ground” mechanism, extensible by type `[← 1, 5]`:

| Area | Source | Effect | Verified in |
|------|--------|--------|-------------|
| chemical | Inkvine | DoT to infantry only; ignitable by any AoE | section 5 §7.1 |
| fire | chemical ignition | damages all; infantry burns instantly; burns out quickly | section 5 §7.1 |
| radiation | Devastator self-destruction | residual area damage `[Rules]` | section 5 §7.1 |
| fresh spice | bloom explosion | periodic damage for a time | section 1 §3 |

Questions `[?]`: is this a single engine mechanism; do areas stack; do they affect
buildings; does Harkonnen flame weaponry create an ignition area by itself.

## 9. Splash and friendly fire

- AoE damage from explosions affects everyone in the radius, including allies `[?]` —
  which weapons have friendly fire (Sonic Tank is confirmed `[← 5]`);
- the splash from the shot that finishes a building does not kill survivors
  (1 second of invulnerability) `[← 3 §7.3]`;
- splash falloff from center to edge `[Rules]` `[?]`.

## 10. Open questions pending verification

Consolidated by section: §1 (whether the model is matrix-based, zeroes, building
armor), §2 (weapon selection, simultaneity, turrets), §3 (hitscan; misses/overshoots/
overdamage), §4 (attack ground, weapons beyond vision), §5 (priorities, pursuit,
guard), §6 (burning: does it burn to death; building stages), §7 (AA model),
§8 (whether area mechanisms are shared), §9 (friendly fire, falloff).
