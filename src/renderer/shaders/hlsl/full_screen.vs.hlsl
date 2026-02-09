// Full-screen triangle vertex shader.
// Generates a triangle that covers the entire viewport from SV_VertexID.

struct VSOutput {
    float4 position : SV_Position;
};

VSOutput vs_main(uint vid : SV_VertexID) {
    VSOutput output;
    output.position.x = (vid == 2) ? 3.0 : -1.0;
    output.position.y = (vid == 0) ? -3.0 : 1.0;
    output.position.z = 1.0;
    output.position.w = 1.0;
    return output;
}
