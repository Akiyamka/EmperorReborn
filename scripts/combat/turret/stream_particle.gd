class_name StreamParticle
extends RefCounted

## One particle of a turret's authored muzzle stream, from the moment it is
## built until it is handed to whichever launcher suits it.
##
## Assembled once by CombatTurretFx and then passed whole: the launch used to
## take fifteen positional parameters, which made both the call and the
## signature unreadable and made adding anything to a stream a fifteen-argument
## edit.
##
## Holds the nodes it draws with, the authored bank data it draws from, and the
## geometry of where it starts and where it is headed.

## Where the particle node is added. Streams are top-level, so this is a scene
## parent rather than a transform parent.
var parent: Node
var node: Node3D
var visual: MeshInstance3D
var quad: QuadMesh
var material: StandardMaterial3D

## The authored FX bank record and its already-loaded sprite sheet.
var bank: Dictionary = {}
var textures: Array[Texture2D] = []

var start := Vector3.ZERO
var direction := Vector3.FORWARD
## Authored cone width. A jet uses a quarter of it -- the source value is the
## spread of a scattering puff bank, far too wide for a directed stream.
var spread_degrees := 0.0
var size := 0.0
var world_gravity := 0.0
## The bullet's real reach. Positive only for a Continuous weapon, which is
## also what makes this particle a candidate for the jet launcher.
var jet_reach_world := 0.0
var duration := 0.0

## Position of this particle within the emission of one source frame, used to
## spread launch times across that frame instead of firing them all at once.
var number := 0
var per_frame := 1


## The flight of one jet particle. Every visual property -- travel, growth,
## tint, fade -- is driven from a single normalized age so they stay in step,
## and this is what the tween carries for the particle's whole life.
class Jet extends RefCounted:
	var start := Vector3.ZERO
	var axis := Vector3.FORWARD
	## Sideways drift, sampled per particle, that opens the column into a plume
	## towards the end of its life.
	var flare_direction := Vector3.ZERO
	var reach := 0.0
	var life := 0.0
	var gravity := 0.0
	var base_size := 0.0
	var textures: Array[Texture2D] = []
	var tint := Color.WHITE
	## Fire banks cool towards ember colour as they burn out; smoke and gas do
	## not.
	var is_fire := false
	var frame_opacities := PackedFloat32Array()
