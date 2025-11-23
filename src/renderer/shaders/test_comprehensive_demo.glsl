// Comprehensive Color Scheme Demo Shader
// Demonstrates all new color uniforms: iPalette, iBackgroundColor, iForegroundColor, iCursorColor
// This shader showcases theme-aware effects and validates the implementation

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec3 terminal = texture(iChannel0, uv).rgb;
    vec3 col = vec3(0.0);

    // Create 8 demo zones showcasing different features
    int zone = int(uv.y * 8.0);
    float x = uv.x;

    if (zone == 7) {
        // Zone 7: Theme-aware rainbow using palette colors 1-6 (standard colors)
        int colorIndex = 1 + int(mod(x * 6.0 + iTime * 2.0, 6.0));
        col = iPalette[colorIndex].rgb;

    } else if (zone == 6) {
        // Zone 6: Background/Foreground gradient
        col = mix(iBackgroundColor.rgb, iForegroundColor.rgb, x);

    } else if (zone == 5) {
        // Zone 5: Pure cursor color demonstration (no opacity applied)
        // Compare with iCurrentCursorColor which includes opacity
        if (x < 0.5) {
            col = iCursorColor.rgb; // Pure color (our implementation)
        } else {
            col = iCurrentCursorColor.rgb; // Color with opacity applied
        }

    } else if (zone == 4) {
        // Zone 4: Grayscale ramp from palette (indices 232-255)
        int grayIndex = 232 + int(x * 24.0);
        col = iPalette[grayIndex].rgb;

    } else if (zone == 3) {
        // Zone 3: Color cube demonstration (indices 16-231)
        // Shows the 6x6x6 RGB cube
        int cubeIndex = 16 + int(x * 216.0);
        col = iPalette[cubeIndex].rgb;

    } else if (zone == 2) {
        // Zone 2: Animated terminal with background tint
        // Demonstrates theme-aware terminal enhancement
        float pulse = 0.5 + 0.5 * sin(iTime * 3.0);
        col = mix(terminal, iBackgroundColor.rgb, 0.3 * pulse);

    } else if (zone == 1) {
        // Zone 1: Color validation grid
        // Shows accuracy of RGB->float conversion
        if (mod(floor(x * 16.0), 2.0) == 0.0) {
            col = vec3(x, 0.0, 1.0 - x); // Custom gradient
        } else {
            col = iPalette[int(x * 255.0)].rgb; // Palette sampling
        }

    } else {
        // Zone 0: Original terminal with subtle foreground accent
        float edge = smoothstep(0.0, 0.1, distance(uv, vec2(0.5)));
        col = mix(terminal, iForegroundColor.rgb * 0.3, edge * 0.2);
    }

    // Add zone separators with theme colors
    float separator = step(0.95, fract(uv.y * 8.0));
    col = mix(col, iForegroundColor.rgb, separator * 0.5);

    // Add cursor position indicator using pure cursor color
    vec2 cursorPos = iCurrentCursor.xy / iResolution.xy;
    float cursorRadius = 0.02;
    float cursorDist = distance(uv, cursorPos);
    if (cursorDist < cursorRadius) {
        col = mix(col, iCursorColor.rgb, 1.0 - smoothstep(0.0, cursorRadius, cursorDist));
    }

    // Final theme-aware vignette
    float vignette = 1.0 - length(uv - 0.5) * 0.5;
    col = mix(iBackgroundColor.rgb, col, vignette);

    fragColor = vec4(col, 1.0);
}