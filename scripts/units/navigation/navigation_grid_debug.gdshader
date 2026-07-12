shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform sampler2D navigation_types : source_color, filter_nearest, repeat_disable;
uniform sampler2D dynamic_blocked : source_color, hint_default_transparent, filter_nearest, repeat_disable;
uniform vec2 grid_origin = vec2(0.0);
uniform vec2 grid_world_size = vec2(256.0);
uniform float surface_offset = 0.5;

varying vec2 world_xz;

void vertex() {
	// TerrainMesh is authored in pre-scale coordinates. A small local normal
	// offset becomes roughly three centimetres after the map root's scale and
	// avoids z-fighting without changing the source terrain.
	VERTEX += NORMAL * surface_offset;
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 nav_uv = (world_xz - grid_origin) / max(grid_world_size, vec2(0.0001));
	vec2 clamped_uv = clamp(nav_uv, vec2(0.0), vec2(0.999999));
	vec4 navigation = texture(navigation_types, clamped_uv);
	vec4 blocked = texture(dynamic_blocked, clamped_uv);
	ALBEDO = mix(navigation.rgb, blocked.rgb, blocked.a);
	ALPHA = max(navigation.a, blocked.a);
}
