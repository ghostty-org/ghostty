// Comprehensive palette validation shader
// Tests array access, bounds checking, and specific color verification

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec3 col = vec3(0.0);

    // Create test zones to validate different aspects
    int zone = int(uv.y * 8.0);
    float x = uv.x;

    if (zone == 7) {
        // Zone 7: Test palette array bounds (0-255)
        int index = int(x * 255.0);
        col = iPalette[index].rgb;
    } else if (zone == 6) {
        // Zone 6: Test standard 16 colors (ANSI colors)
        int index = int(x * 16.0);
        col = iPalette[index].rgb;
    } else if (zone == 5) {
        // Zone 5: Test 6x6x6 color cube (indices 16-231)
        int cubeIndex = 16 + int(x * 216.0); // 216 = 6*6*6
        col = iPalette[cubeIndex].rgb;
    } else if (zone == 4) {
        // Zone 4: Test grayscale ramp (indices 232-255)
        int grayIndex = 232 + int(x * 24.0); // 24 grayscale colors
        col = iPalette[grayIndex].rgb;
    } else if (zone == 3) {
        // Zone 3: Color format validation - should show red gradient
        // Testing that RGB conversion from 0-255 to 0.0-1.0 is correct
        float red = x;
        col = vec3(red, 0.0, 0.0);
    } else if (zone == 2) {
        // Zone 2: Background color test
        col = iBackgroundColor.rgb;
    } else if (zone == 1) {
        // Zone 1: Foreground color test
        col = iForegroundColor.rgb;
    } else {
        // Zone 0: Cursor color test (pure color without opacity)
        col = iCursorColor.rgb;
    }

    // Add zone separators
    if (fract(uv.y * 8.0) > 0.95) {
        col = mix(col, vec3(1.0), 0.5);
    }

    fragColor = vec4(col, 1.0);
}