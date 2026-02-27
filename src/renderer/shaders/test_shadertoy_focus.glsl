// Test shader for iTimeFocus and iFocus
// Shows border when focused, green fade that restarts on each focus gain
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    // Sample the terminal content
    vec4 terminal = texture2D(iChannel0, uv);
    vec3 color = terminal.rgb;

    if (iFocus > 0) {
        // FOCUSED: Add border and fading green overlay

        // Calculate time since focus was gained
        float timeSinceFocus = iTime - iTimeFocus;

        // Green fade: starts at 1.0 (full green), fades to 0.0 over 3 seconds
        float fadeOut = max(0.0, 1.0 - (timeSinceFocus / 3.0));

        // Add green overlay that fades out
        color = mix(color, vec3(0.0, 1.0, 0.0), fadeOut * 0.4);

        // Add border (5 pixels)
        float borderSize = 5.0;
        vec2 pixelCoord = fragCoord;
        bool isBorder = pixelCoord.x < borderSize ||
                       pixelCoord.x > iResolution.x - borderSize ||
                       pixelCoord.y < borderSize ||
                       pixelCoord.y > iResolution.y - borderSize;

        if (isBorder) {
            // Bright cyan border that pulses subtly
            float pulse = sin(timeSinceFocus * 2.0) * 0.1 + 0.9;
            color = vec3(0.0, 1.0, 1.0) * pulse;
        }
    } else {
        // UNFOCUSED: Solid red overlay (no border)
        color = mix(color, vec3(1.0, 0.0, 0.0), 0.3);
    }

    fragColor = vec4(color, 1.0);
}
