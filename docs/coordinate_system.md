# Coordinate-system contract

Gameplay code uses Godot world coordinates: `+Y` is up, world `X/Z` form the
ground plane, and navigation `Vector2i(x, y)` maps to world `(X, Z)`.

## Semantic directions

- A regular Godot `Node3D`, including units and cameras, faces local `-Z`.
- Converted Emperor building models expose their door/apron on local `+Z`.
- Unit callers use `Unit.facing_direction()` and `Unit.face_direction()`.
- Building callers use `Building.exit_direction()`.
- Code shared by other spatial nodes uses `SpatialOrientation`.

Gameplay code must not infer a semantic front from `basis.z` directly. The
sign is an asset-boundary detail, and copying yaw between a building and a
unit points their semantic fronts in opposite directions.

## Imported visuals and rules footprints

The XBF converter reflects source Z when converting the original left-handed
model space to Godot. Unit wrapper scenes rotate `VisualRoot` by 180 degrees;
that presentation transform does not change the unit root's `-Z` gameplay
front.

Imported building occupy rows are reversed once by `import_rules.gd`. After
import, row zero lies toward local `-Z`, row indices advance toward local `+Z`,
and skirt (`S`) rows therefore line up with `Building.exit_direction()`.

`BuildingFootprint.nav_cells_by_marker()` is the single runtime mapping from
these local rows to navigation cells. It applies the building's world
transform, so placement occupancy, build radius, solid blockers, and no-stop
skirt cells agree for rotated buildings.

## Rotation rules

Entity directions are horizontal: pitch and roll do not affect movement,
production exits, or footprint orientation. Yaw is handled in world space, so
a rotated parent container does not change a unit's requested world heading.

Tests cover the four cardinal building directions, a rotated asymmetric
footprint, and preservation of a rotated skirt as a passable no-stop exit.
