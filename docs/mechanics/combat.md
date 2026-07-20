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

- Basic scheme: a **bullet** references a **warhead** (§2), and a target has an
  **armor type**; final damage = bullet damage × the **percentage for the
  “warhead × armor” pair** from the matrix in `Rules.txt` `[Rules]`;
- the matrix expresses specializations: anti-infantry, anti-vehicle, and anti-air
  weapons are matrix rows rather than separate mechanics `[?]`;
- **zero pairs** are represented directly by zeroes in the matrix (for example,
  every normal warhead has a zero entry for `Invulnerable`) `[Rules]`; target-domain
  restrictions such as air-only fire are separate bullet flags (§7);
- buildings use the same armor-type namespace and matrix: `Armour` is present on
  building entries as well as units (`Building`, `CY`, `Heavy`, etc.) `[Rules]`.

## 2. Weapon model: turret → bullet → warhead

Weapons in `Rules.txt` are a pipeline of three entities (verified):

- **Turret** — the projectile-emission point on a unit:
  - may be **fixed** (rigidly aligned with heading — firing requires turning the
    hull) or **rotating**;
  - a rotating turret may have a limited yaw sector. If the target lies outside
    that sector, the turret turns to its authored limit while the unit turns its
    hull until the weapon can finish aiming (verified with the Minotaurus);
  - when an attack order ends, a rotated turret returns to its authored forward
    pose at the same rule-defined rotation speed; movement/idle animations do
    not snap it to rest or preserve a hidden previous aiming angle (verified);
  - **turrets on turrets** are supported — nesting for aiming along different
    axes, where different model parts rotate independently (for example, the
    mount horizontally and the barrel vertically);
- **Bullet** — the shot emitted by a turret. It owns **base damage, range, speed,
  trajectory, target-domain flags, special-effect flags, and explosion visuals**
  `[Rules]`. A physical bullet's visible model comes from its `ArtIni` `Xaf`
  mapping (for example, `KobraHowitzer_B -> shell.xaf`), independently of its
  impact effect and debris. A conceptual/hitscan shot is still a Bullet entry,
  marked by `Speed = -1`; this is used by ordinary guns and knives as well as
  lasers;
- **Warhead** — the bullet's reference to the §1 percentage matrix. Warhead
  entries contain only armor percentages; they do not own damage, effects, or
  visuals `[Rules]`.

Consequently, Deviator gas, Leech/Contaminator infection, ignition and related
effects are **bullet properties**, not warhead properties. `Leech_B` and
`Contaminator_B` intentionally have damage and effect fields but no warhead;
their `Damage` is the direct fallback for targets that cannot receive the effect
`[Rules]`.

Other weapon properties on a unit:

- a unit carries **one or more weapons** `[← 5: Sardaukar, Devastator]` `[Rules]`;
  selection logic when several are present: by **target type** `[?]`; can two
  weapons operate **simultaneously against different targets** `[?]`;
- reload/rate of fire is per weapon `[Rules]`. A firing cycle consists of the
  complete authored `Fire N` XBF clip followed by `ReloadCount`; the reload
  value uses the model's 20 Hz frame domain and starts only after the clip ends
  (verified). Projectile events inside the clip follow the animated barrel
  recoils: the Minotaurus emits four sequential shells from its four muzzles
  during one 31-frame `Fire 0` clip, then reloads. `TurretBulletCount` remains a
  separate rule for several projectiles emitted by one event. Once the firing
  clip has started, its authored salvo events are committed; the next barrel
  does not have to pass a fresh one-frame aim-tolerance check;
- suppression slows attacks `[← 5 §1]`.

## 3. Projectiles and trajectories

Projectiles (“bullets” from §2) are **physical 3D objects** with speed and
trajectory parameters `[← 1 §1: collisions]` `[Rules]`. Trajectory behavior
(verified):

- trajectory bullets use the global `BulletGravity` together with their
  `MaxRange` and the firing joint's elevation limits. There is no separate
  per-bullet `ArcHeight` field in `Rules.txt`: `Trajectory=true` enables the
  ballistic delivery, while a weapon that permits both solutions uses the
  flatter low arc and a minimum-elevation weapon (such as the deployed mortar)
  selects the high arc. The barrel follows the same solution as the projectile;
- **conceptual bullets** (`Speed = -1`) hit instantly; there are 19 such entries
  in the normalized rules, including ordinary firearms, knives, heavy guns, and
  both lasers. `IsLaser` is a separate bullet flag rather than the definition of
  hitscan `[Rules]`; lasers never miss (verified);
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

- `MinRange`/`MaxRange` are measured from the stable gameplay origin of the
  firing entity. The animated muzzle is the projectile spawn point, but moving,
  elevating, or entering a `Fire` pose cannot move the weapon itself into or out
  of gameplay range (verified);
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

- The ability to hit air is the Bullet `AntiAircraft` flag `[Rules]`;
- air is unreachable by non-AA weapons `[← 5 §3]`, except for a landed plane
  (a ground unit `[← 5 §3]`);
- air-only weapons exist: `ATHEATADP_B` combines `AntiAircraft = true` with
  `AntiGround = false` `[Rules]`.

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

Consolidated by section: §1 (whether specialization is entirely matrix-driven),
§2 (weapon selection, simultaneity, runtime turret aiming), §3 (misses/overshoots/
overdamage), §4 (attack ground, weapons beyond vision), §5 (priorities, pursuit,
guard), §6 (burning: does it burn to death; building stages), §8 (whether area
mechanisms are shared), §9 (friendly fire, falloff).
