shader_type spatial;

// Decorative and empty indicator layers use additive blending so their bright
// segments glow without changing the alpha-blended filled status layers.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

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
