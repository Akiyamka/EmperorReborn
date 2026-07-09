# EmperorReborn Agent Notes

## Building XBF Imports

Emperor: Battle for Dune ships building model variants with suffix families:

- `H*`: high-detail building meshes and construction/damage states.
- `M*`: medium-detail LOD meshes.
- `L*`: low-detail LOD meshes.

For EmperorReborn, import only the `H*` building variants. The original game is old enough that even `H*` meshes are low-poly by modern standards, so `M*` and `L*` variants add asset and runtime complexity without meaningful value.

When implementing building importers, examples such as `ATBarracks` should use files like `at_barracks_H0.xbf`, `at_barracks_h1.xbf`, `at_barracks_h2.xbf`, `at_barracks_h3.xbf`, and `AT_barracks_HC.XbF`, and should ignore matching `*_M*` and `*_L*` files.

## Code Rules
- Dont put all logic in single file main.gd
