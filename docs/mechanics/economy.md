# Emperor: Battle for Dune Mechanics — 3. Economy

This section describes the game's **financial loop**: where credits come from, where they go,
and which systems (power, repair) depend on that loop. Logic is here; numbers are in `Rules.txt`.

**Labels:**
- `[?]` — remaining question;
- `[Rules]` — parameterized in `Rules.txt`;
- `[design]` — an intentional deviation of our implementation from the original;
- `[→ N]` — details in section N of the series.

Status: **verified**.

---

## 1. Resource loop

The game has one resource—**spice**—converted into its only currency—**credits**:

```
spice field (sand) → harvester collects → carryall transports → refinery
    → gradual unloading → player credits → construction/production
```

All expenses (buildings, units, upgrades, repair, starport) are paid in credits.
There are no other resources or currencies; power (§5) is not a stockpiled resource but a
balance indicator.

The world aspect of spice (fields, blooms, regeneration, toxicity) is described in section 1
§3; this document covers only extraction and money.

---

## 2. Harvester and carryall

### 2.1 Harvester

- Collects spice from a field until its bunker is full `[Rules: capacity]`; yield depends on
  local density (see section 1 §3);
- after filling up, returns to a refinery and unloads; this behavior is **automatic**
  (the “field → unload → field” cycle), though the player can redirect or recall it manually;
- if a harvester is destroyed, its collected cargo is **lost permanently**;
- the **main worm lure**: high “tastiness” plus constant movement on sand (see section 1 §4);
- additional harvesters are built at the **factory** as ordinary units.

### 2.2 Carryall — automatic logistics

A carryall is an airborne harvester transport. Rules:

- **fully automatic**, and cannot be controlled directly;
- all of a player's carryalls operate as a **shared pool**: they continuously monitor harvesters
  facing a long journey and assist them, distributing tasks among themselves (a carryall is not
  “assigned” to a particular harvester or refinery);
- if a carryall is shot down **with a harvester aboard, both are destroyed**;
- additional carryalls are built in the **hangar**.

### 2.3 Initial units and replacement

The rules for replenishing harvesters and carryalls are asymmetric:

| Event | What happens |
|-------|--------------|
| A refinery is built | **A carryall plus a harvester** fly in from off-map; both remain with the player |
| An additional refinery dock is built (§3) | It includes **one more harvester, without a carryall** |
| A harvester is lost, and there are **fewer harvesters than refineries** | After a timeout `[Rules]`, a carryall brings a new harvester from off-map to an empty refinery and **leaves the map** (it does not remain) |
| A harvester from an additional dock is lost | **Not replaced** (replacement counts refineries, not docks) |
| A carryall is lost | **Not replaced**—it can only be built in the hangar |

Consequences:

- a harvester is a replaceable consumable (up to “one per refinery”), while a carryall is a
  non-replaceable asset whose losses accumulate;
- when carryalls are scarce, harvesters travel under their own power: slowly, spending longer
  on sand, and, because of their low speed, **being virtually unable to escape a worm already
  attacking them**—the economy degrades in a cascade;
- all three Houses have a hangar (the Ordos lack only an aircraft reloading pad—see section 2
  §2), so all Houses can replenish carryalls equally.

---

## 3. Refineries

- The conversion point: unloading is **gradual**, and credits are added as unloading proceeds
  `[Rules: speed]`;
- construction includes a carryall plus harvester (§2.3)—the refinery is the basic unit for
  scaling the economy;
- the **“additional dock” upgrade** (ordered from the upgrades panel `[→ 6]`, maximum **two**
  per refinery) changes the automatically selected refinery's own state rather than creating a
  separate building. It permits several harvesters to unload **simultaneously**; each dock, when
  opened, grants an additional harvester (without a carryall and without replacement if lost);
- multiple refineries diversify risk and, unlike docks, participate in the harvester-replacement
  mechanism.

---

## 4. Starport

A Guild building for ordering units—the mechanic is inherited from Dune 2000:

- units are **ordered as a package**, with a maximum of **10 units** per order, at prices that
  **fluctuate** around the nominal price `[Rules: fluctuation bounds]`—sometimes cheaper than
  the factory, sometimes more expensive;
- not the **entire roster** can be ordered: starport availability is a separate unit flag
  `[Rules: starportable]`;
- a paid order is delivered by a **Guild frigate** to the starport pad after a flight delay;
- if the **starport is destroyed** before the frigate arrives, the order is **cancelled**;
- its purpose is to exchange money for **deployment speed** (a package of units immediately,
  bypassing the factory queue) and to add a market-game element to prices.

---

## 5. Power

The second, intangible economic loop is the **power balance**:

- **windtraps** produce power and buildings consume it `[Rules]`;
- power is an immediate “production vs. consumption” balance; it is not stockpiled;
- a **damaged windtrap produces less power** (output is proportional to health `[Rules]`);
- under a **shortage**:
  - production and construction **slow down** `[Rules: coefficient]`;
  - the **radar (outpost) shuts down**;
  - **power-dependent turrets** shut down (see below).

**Two-tier turrets.** Every House has two turrets: a basic **autonomous** turret that does not
depend on the power grid, and an advanced turret that is **more powerful, more expensive, and
power-dependent**, going dark during a shortage. Attacking windtraps therefore disables the
**strong** defensive tier, leaving the defender with basic turrets—the stronger the defense,
the more vulnerable it is to a power attack.

---

## 6. Spending credits

- **Gradual payment**: money for a building/unit is deducted during construction, rather than
  paid entirely in advance (the Westwood “pay as you go” model);
- if there is **not enough money**, construction pauses and waits for income;
- **cancelling** an item under construction gives a **full refund** of what has already been paid;
- building **upgrades** are bought with credits `[→ 6]`;
- building **repair** costs credits (§7);
- **ammunition is free and unlimited**—firing is not an expense for anyone.

---

## 7. Repair and selling

### 7.1 Building repair

Any building can be repaired for credits: repair mode is enabled, health is restored gradually,
and money is deducted as it proceeds `[Rules: price/speed]`.

### 7.2 Unit repair — faction asymmetry

There is **no** universal vehicle-repair mechanism (a repair-pad building)—such a building was
**cut** from the game. Unit recovery is a House property (see section 2 §2):

| House | Vehicle recovery |
|-------|------------------|
| Atreides | repair vehicles (a unit repairs a unit) |
| Harkonnen | **none**—damage is irreversible |
| Ordos | self-regeneration |

This is not a minor balance detail, but part of the Houses' philosophy: Harkonnen damage
irreversibility pushes them toward trades, while Ordos regeneration favors hit and run.

### 7.3 Selling buildings

- The refund is **50%** of the cost;
- selling is instant (apart from the animation);
- in the original, infantry deployed from a sold building—a questionable mechanic.

> `[design]` We do **not** reproduce infantry deployment **on sale**. Units appear
> only when a building is **destroyed** (“survivors”), and on appearing receive
> **1 second of invulnerability**—so that the splash damage from the same artillery
> which finished off the building does not kill them immediately.

---

## 8. Crates (bonus boxes)

Contrary to the initial assumption, they **do** exist. There are two types:

- **skirmish crates** (disableable in settings, like worms and tornadoes):
  - appear **periodically, at a random passable location** on the map `[Rules: interval]`;
  - visually, **all are identical**—their contents are unknown until picked up (a lottery);
  - contents: **money**, **units**, **abilities**, **experience** `[Rules]`;
  - opened by a unit **touching** them;
  - **disappear after a timeout** if not collected `[Rules]`;
- **story crates**—placed on the map in advance by the designer:
  - **thematic**: look different from one another (unlike skirmish crates);
  - **fixed loot**—the contents are set by the map, not a lottery;
  - some open on contact, while others must be **destroyed with damage**.

---

## 9. What the economy does NOT have (negative checks)

- **no silos or credit cap**—the storage mechanic was **cut** (silo models remain in the game
  files, but do not participate in gameplay);
- **no repair pad**—also cut (§7.2);
- **no secondary resources**—only spice;
- **no credit transfers to allies** or trading between players;
- **no passive income** from buildings—only harvesting (and one-time crates/orders).

The pair of “cut, but traces remain in the assets” features (silos and repair pad) is useful
when examining the game files: the presence of a model ≠ the presence of a mechanic.
