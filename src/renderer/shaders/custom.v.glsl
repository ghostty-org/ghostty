#version 300 es

void main(){
    vec2 position;
    position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? -1. : 1.;
    position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 1. : -1.;
    gl_Position = vec4(position.xy, 0.0f, 1.0f);
}
