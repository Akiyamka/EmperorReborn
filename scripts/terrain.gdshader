shader_type spatial;

// Tiled theme texture (UV1 from the XBF mesh) modulated by the map's baked
// ground-tone layer (texture.dat, 2048x2048 = 8192x8192 XBF units projected
// on world XZ). tone_neutral is the byte value that means "unmodified".
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
// test.CPT decoded: the map's baked ground color (mottling, detail patches
// and shading composited at bake time), 4 XBF units per texel, projected on
// world XZ. Combined with the tiled detail texture as D3D MODULATE2X
// (multiply, x2, clamp) — tone_scale 2.0 keeps mid-gray ground neutral.
uniform sampler2D ground_color : source_color, filter_linear, repeat_disable, hint_default_white;
uniform float tone_scale = 3.0;
// Multiplying an orange tile by the orange CPT squares the color and
// oversaturates; pull the CPT contribution back toward its luminance.
uniform float tone_saturation : hint_range(0.0, 1.0) = 0.19;
uniform float ground_world_size = 512.0;
// Set per surface when its UVs stay inside [0,1] on that axis: transition
// strips (cragsandjoin, smooth, ...) span exactly 0..1, and wrap sampling at
// the border bleeds the opposite edge of the texture in as a thin seam line.
uniform bool clamp_u = false;
uniform bool clamp_v = false;
// Low-frequency theme "mottle" texture (e.g. Arrakistexture.TGA) projected
// planar over the world: the large rust blotches that break up the tiling.
// Applied as a ratio to its own average color, so it modulates rather than
// tints. Strength 0 disables it.
uniform sampler2D mottle_tex : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform vec3 mottle_mean = vec3(1.0);
uniform float mottle_strength = 0.0;
uniform float mottle_world_size = 48.0;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 uv = UV;
	// 1.5-texel inset keeps the bilinear footprint away from the wrap border
	// on the first mip levels; farther mips are too blurred to show the seam.
	vec2 inset = 1.5 / vec2(textureSize(albedo_tex, 0));
	if (clamp_u) {
		uv.x = clamp(uv.x, inset.x, 1.0 - inset.x);
	}
	if (clamp_v) {
		uv.y = clamp(uv.y, inset.y, 1.0 - inset.y);
	}
	vec3 base = texture(albedo_tex, uv).rgb;
	// Map geometry is Z-mirrored from D3D space, so world Z maps directly to V.
	vec2 ground_uv = vec2(world_xz.x, world_xz.y) / ground_world_size;
	// min() mimics the D3D-era framebuffer clamp of MODULATE2X.
	vec3 tone_color = min(texture(ground_color, ground_uv).rgb * tone_scale, vec3(1.0));
	tone_color = mix(vec3(dot(tone_color, vec3(0.299, 0.587, 0.114))), tone_color, tone_saturation);
	vec3 mottle = texture(mottle_tex, world_xz / mottle_world_size).rgb;
	vec3 variation = mix(vec3(1.0), mottle / mottle_mean, mottle_strength);
	ALBEDO = base * tone_color * clamp(variation, 0.0, 1.5);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
