shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;


void vertex() {
	// Face each soft particle card toward the active camera while preserving the
	// random scale supplied by ParticleProcessMaterial.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		MAIN_CAM_INV_VIEW_MATRIX[0],
		MAIN_CAM_INV_VIEW_MATRIX[1],
		MAIN_CAM_INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX *= mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
}


void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float soft_disc = 1.0 - smoothstep(0.2, 1.0, length(centered_uv));
	float breakup = 0.78
		+ 0.22 * sin(centered_uv.x * 8.0 + centered_uv.y * 3.0)
		* sin(centered_uv.y * 7.0 - centered_uv.x * 2.0);
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * soft_disc * breakup;
}
