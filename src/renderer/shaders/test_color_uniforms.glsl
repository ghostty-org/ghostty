// Simple color validation shader - just tints with background color

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord.xy / iResolution.xy;

    // Get original terminal content
    vec3 terminal = texture(iChannel0, uv).rgb;

    // Simple test: tint terminal content with background color
    vec3 tinted = mix(terminal, iBackgroundColor.rgb, 0.1);

    fragColor = vec4(tinted, 1.0);
}