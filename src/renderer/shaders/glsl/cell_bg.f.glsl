#version 430 core

in CellBgVertexOut {
    flat vec4 color;
} in_data;

layout(location = 0) out vec4 out_FragColor;

void main() {
    out_FragColor = in_data.color;
}
