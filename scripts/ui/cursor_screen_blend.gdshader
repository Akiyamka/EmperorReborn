shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The isolated !-surface viewport is cleared to opaque black. The original 3D
// cursor effects accumulate there, then Screen makes that black neutral while
// coloured and white geometry brightens the game image below it.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

void fragment() {
	vec4 cursor = texture(TEXTURE, UV);
	vec3 backdrop = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	vec3 screened = vec3(1.0) - (vec3(1.0) - backdrop) * (vec3(1.0) - cursor.rgb);
	// `screened` is already the final framebuffer colour. The effect viewport
	// deliberately carries no transparency: its guaranteed-black empty pixels
	// reproduce `backdrop` exactly through the Screen equation.
	COLOR = vec4(screened, 1.0);
}
