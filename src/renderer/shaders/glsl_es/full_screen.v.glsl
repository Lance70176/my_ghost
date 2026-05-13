#version 310 es

void main() {
  vec4 position;
  position.x = (gl_VertexID == 2) ? 3.0 : -1.0;
  position.y = (gl_VertexID == 0) ? -3.0 : 1.0;
  position.z = 1.0;
  position.w = 1.0;

  gl_Position = position;
}
