#version 330 core

void main() {
  vec4 position;
  position.x = (gl_VertexID == 2) ? 3.0 : -1.0;
  position.y = (gl_VertexID == 0) ? -3.0 : 1.0;
  position.z = 1.0;
  position.w = 1.0;

  // Single triangle is clipped to viewport.
  //
  // X <- vid == 0: (-1, -3)
  // |\
  // | \
  // |  \
  // |###\
  // |#+# \ `+` is (0, 0). `#`s are viewport area.
  // |###  \
  // X------X <- vid == 2: (3, 1)
  // ^
  // vid == 1: (-1, 1)

  gl_Position = position;
}
