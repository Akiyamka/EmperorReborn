shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// PlaneMesh supplies local 0..1 UVs. Clamp sampling is intentional: one mound
// texture covers one runtime mound mesh and can never tile across its bounds.
uniform sampler2D spice_mound_tex : source_color, filter_linear, repeat_disable;

void fragment() {
	vec4 mound = texture(spice_mound_tex, UV);
	ALBEDO = mound.rgb;
	ALPHA = mound.a;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
