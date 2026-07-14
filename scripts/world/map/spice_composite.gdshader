shader_type canvas_item;
render_mode blend_disabled;

// This shader runs only when the mutable spice grid changes. It composites
// all overlapping, rotated cell stamps into one map-wide overlay texture.
uniform sampler2D spice_field_mask : filter_nearest, repeat_disable, hint_default_black;
uniform sampler2D spice_field_tex : source_color, filter_linear, repeat_enable, hint_default_black;
uniform float spice_stamp_scale : hint_range(1.0, 6.0) = 5.0;


float spice_cell_random(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453123);
}


float spice_block_density(ivec2 block, vec2 mask_grid_size) {
	vec2 first_cell = vec2(block * 2);
	float density = texture(spice_field_mask, (first_cell + vec2(0.5, 0.5)) / mask_grid_size).r;
	density += texture(spice_field_mask, (first_cell + vec2(1.5, 0.5)) / mask_grid_size).r;
	density += texture(spice_field_mask, (first_cell + vec2(0.5, 1.5)) / mask_grid_size).r;
	density += texture(spice_field_mask, (first_cell + vec2(1.5, 1.5)) / mask_grid_size).r;
	return density * 0.25;
}


void fragment() {
	vec2 mask_grid_size = vec2(textureSize(spice_field_mask, 0));
	vec2 block_grid_size = mask_grid_size * 0.5;
	ivec2 field_block = ivec2(floor(UV * block_grid_size));
	vec4 composite = vec4(0.0);
	for (int offset_y = -2; offset_y <= 2; offset_y++) {
		for (int offset_x = -2; offset_x <= 2; offset_x++) {
			ivec2 stamp_block = field_block + ivec2(offset_x, offset_y);
			if (stamp_block.x < 0 || stamp_block.y < 0 || stamp_block.x >= int(block_grid_size.x) || stamp_block.y >= int(block_grid_size.y)) {
				continue;
			}
			vec2 stamp_block_f = vec2(stamp_block);
			float spice_density = spice_block_density(stamp_block, mask_grid_size);
			if (spice_density <= 0.0) {
				continue;
			}
			float rotation = spice_cell_random(stamp_block_f) * 6.28318530718;
			float scale_variation = mix(0.9, 1.1, spice_cell_random(stamp_block_f + vec2(19.19, 7.73)));
			float stamp_size = spice_stamp_scale * scale_variation;
			vec2 stamp_center = stamp_block_f * 2.0 + vec2(1.0);
			vec2 stamp_offset = UV * mask_grid_size - stamp_center;
			float rotation_sin = sin(rotation);
			float rotation_cos = cos(rotation);
			stamp_offset = mat2(
				vec2(rotation_cos, -rotation_sin),
				vec2(rotation_sin, rotation_cos)
			) * stamp_offset;
			vec2 stamp_uv = stamp_offset / stamp_size + vec2(0.5);
			if (all(greaterThanEqual(stamp_uv, vec2(0.0))) && all(lessThan(stamp_uv, vec2(1.0)))) {
				vec4 spice = texture(spice_field_tex, stamp_uv);
				float stamp_alpha = spice.a * spice_density;
				composite.rgb = spice.rgb * stamp_alpha + composite.rgb * (1.0 - stamp_alpha);
				composite.a = stamp_alpha + composite.a * (1.0 - stamp_alpha);
			}
		}
	}
	COLOR = composite;
}
