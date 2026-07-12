shader_type spatial;

// The original halo textures are opaque TGAs with a black background.  Their
// brightness supplies a synthetic alpha channel: it keeps the soft edges while
// ordinary alpha blending preserves the texture's original colours.
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D indicator_texture : source_color;
uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform bool apply_radial_mask = false;

void fragment() {
	vec4 color = texture(indicator_texture, UV);
	vec2 centered = UV - vec2(0.5);
	float angle = atan(centered.x, -centered.y);
	if (angle < 0.0) {
		angle += TAU;
	}
	if (apply_radial_mask && angle / TAU > fill) {
		discard;
	}
	float alpha = max(color.r, max(color.g, color.b));
	ALBEDO = color.rgb / max(alpha, 0.001);
	ALPHA = alpha;
}
