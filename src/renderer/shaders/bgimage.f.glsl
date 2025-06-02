#version 330 core

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

uniform sampler2D image;
uniform float opacity;

// Converts a color from linear to sRGB gamma encoding.
vec4 unlinearize(vec4 linear) {
    bvec3 cutoff = lessThan(linear.rgb, vec3(0.0031308));
    vec3 higher = pow(linear.rgb, vec3(1.0/2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear.rgb * vec3(12.92);

    return vec4(mix(higher, lower, cutoff), linear.a);
}

void main() {
	// Normalize the coordinates
	vec2 norm_coord = tex_coord;
	norm_coord = fract(tex_coord);

    // Our texture is stored with an sRGB internal format,
    // which means that the values are linearized when we
    // sample the texture, but for now we actually want to
    // output the color with gamma compression, so we do
    // that.
	vec4 color = texture(image, norm_coord);
    color = unlinearize(color);

	out_FragColor = vec4(color.rgb * color.a * opacity, color.a * opacity);
}
