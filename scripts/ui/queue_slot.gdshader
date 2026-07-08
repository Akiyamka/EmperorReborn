shader_type canvas_item;

// Clockwise radial build-progress wipe: the colored icon (TEXTURE) is
// revealed over the grey icon starting at 12 o'clock, like classic C&C.
uniform sampler2D grey_texture;
uniform float progress : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 centered = UV - vec2(0.5);
	// 0 at the top, growing clockwise (UV y points down).
	float angle = atan(centered.x, -centered.y);
	if (angle < 0.0) {
		angle += TAU;
	}
	vec4 colored = texture(TEXTURE, UV);
	vec4 grey = texture(grey_texture, UV);
	COLOR = angle / TAU <= progress ? colored : grey;
}
