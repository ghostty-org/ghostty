#version 430 core

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
};

#define CURSORSTYLE_BLOCK        0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR          2
#define CURSORSTYLE_UNDERLINE    3
#define CURSORSTYLE_LOCK         4

layout(binding = 0) uniform sampler2D iChannel0;

// These are unused currently by Ghostty:
// layout(binding = 1) uniform sampler2D iChannel1;
// layout(binding = 2) uniform sampler2D iChannel2;
// layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );

// Vulkan-only: wrap `texture(sampler2D, vec2)` so iChannel0
// (back_texture, in Vulkan top-left orientation) appears to
// the author in OpenGL/shadertoy convention (lower-left).
// Defined BEFORE the `#define`, so the inner `texture(s, ...)`
// call here resolves to the GLSL built-in, not back to ourselves
// (no preprocessor recursion).
#ifdef GHASTTY_VULKAN
vec4 _ghastty_tex2d(sampler2D s, vec2 uv) {
    return texture(s, vec2(uv.x, 1.0 - uv.y));
}
#define texture _ghastty_tex2d
#endif

void main() {
#ifdef GHASTTY_VULKAN
    mainImage(_fragColor, vec2(gl_FragCoord.x, iResolution.y - gl_FragCoord.y));
#else
    mainImage(_fragColor, gl_FragCoord.xy);
#endif
}
