# Open Questions

This document tracks source-model markers whose original runtime behavior is
not established yet. They are deliberately not assigned compatibility
behavior merely because their names begin with `#`.

## Building `#` markers not fully resolved

**Resolved boundary:** Building markers referenced by a decoded XBF FX
`start`/`stop` event and a valid FX bank are converted as attachment effects.
This includes lights as well as authored smoke, fire, flame, dry-ice, blood,
plasma, red-flash, garage, movie, and parts banks. Marker lookup is
case-insensitive to tolerate inconsistent source capitalization.

The following real object names occur in building `H*` models but either have
no decoded FX event that establishes how Emperor's runtime treats them, or
reference a missing asset. Compare them against the original game before
implementing them:

| Marker(s) | Source model examples | Question to verify |
| --- | --- | --- |
| `#lightning` | `OR_Palace_H0/H1/H2` | Animated geometry, a procedural beam, or an attachment effect? |
| `#blueflame` | `HK_Palace_H0/H1/H2/H3/HC` | Always-visible animated mesh or bank-driven flame? |
| `#boom` | `HK_Windtrap_H3`, `HK_UpgrdWindtrap_H3` | Destruction flash marker or visible debris geometry? |
| `#fountain` | `TL_IN_Greenhouse_H0` | Water particle emitter or an animated mesh? |
| `#dribble`, `#dribble01` | `TL_Fleshvat_H0` | Liquid emitter behavior and timing? |
| `#bigchimney` | `HL_IN_OxygenGen_H0`, `HL_IN_Oxygen_H0/H1/H2` | Smoke emitter, anchor, or visible chimney component? |
| `#movie` | `AT_Hanger_H0` | Parent/control node for the numbered `#movieNN` FX attachments? |
| `#Parts2`, `#Parts2X` | Repair-pad models | Gameplay repair particles or ordinary animated parts? |
| `#pivot` | `AK_IN_RepairPad_H0` | Transform-only animation pivot or gameplay attachment? |
| `#akira00`–`#akira03` | `IN_GU_MegaCannon_H0/H1/H2` | Weapon/control anchors or visible effect geometry? |
| `#Seagul01/03/04` | `CN_IN_Seaguls_H0` | Procedural ambient birds or model animation? |
| `#vulture`, `#vulture01`–`03` | `AK_IN_Vultures_H0` | Procedural ambient birds or model animation? |
| `#smoke1`–`#smoke3`, `#smokey5`, `#smokey6`, `#_smoke` | Various building and ambient models | Additional emitters, or meshes controlled by an undecoded event form? |
| `#ExplosionParent` | `HK_Barracks_H3` | Parent used by procedural destruction or ordinary hierarchy? |
| `#Vent` | `CN_IN_Whale_H0` | Its decoded bank requests `@Wake.tga`, which is absent from the shipped texture directory. Is the wake supplied procedurally or under another name? |
| `#::0`, `#::1` | `HK_GunTurret_H0` | Weapon hardpoints encoded with a prefixed legacy marker? |
| `#>>0` | `IN_GU_MegaCannon_H0/H1/H2`, `IN_IX_MegaCannon_H0/H1/H2` | Weapon target/muzzle anchor encoded with a prefixed legacy marker? |
| `#'~~0`, `#~~0boxes`, `#~~1`, `#_aircrash_parent~~0` | `OR_IN_Indi`, `G_Crates`, `air_crash` | Collision hierarchy variant or procedural object grouping? |

### Already understood special markers

- `#~~0` is authored collision geometry. An FX event may still target that
  transform (for example campfire/smoke assets), but its mesh stays hidden.
- `#^^0` supplies halo-anchor bounds and is already consumed by the runtime.
- Ordinary `#light…` variants and markers backed by decoded FX events with
  available textures are no longer open questions.

When checking the original game, record whether each marker is visible at
idle, only during an animation/damage state, camera-facing, particle-emitting,
or controlled by gameplay. Those distinctions determine whether it belongs
in model baking, animation tracks, or runtime simulation.
