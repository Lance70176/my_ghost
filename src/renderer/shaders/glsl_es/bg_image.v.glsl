#include "common.glsl"

layout(binding = 0) uniform sampler2D image;

layout(location = 0) in float in_opacity;
layout(location = 1) in uint info;

// 4 bits of info.
const uint BG_IMAGE_POSITION = 15u;
const uint BG_IMAGE_TL = 0u;
const uint BG_IMAGE_TC = 1u;
const uint BG_IMAGE_TR = 2u;
const uint BG_IMAGE_ML = 3u;
const uint BG_IMAGE_MC = 4u;
const uint BG_IMAGE_MR = 5u;
const uint BG_IMAGE_BL = 6u;
const uint BG_IMAGE_BC = 7u;
const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
const uint BG_IMAGE_FIT = 3u << 4;
const uint BG_IMAGE_CONTAIN = 0u << 4;
const uint BG_IMAGE_COVER = 1u << 4;
const uint BG_IMAGE_STRETCH = 2u << 4;
const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
const uint BG_IMAGE_REPEAT = 1u << 6;

flat out vec4 bg_color;
flat out vec2 v_offset;
flat out vec2 v_scale;
flat out float opacity;
flat out uint v_repeat;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    vec4 position;
    position.x = (gl_VertexID == 2) ? 3.0 : -1.0;
    position.y = (gl_VertexID == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;

    gl_Position = position;

    opacity = in_opacity;

    v_repeat = info & BG_IMAGE_REPEAT;

    vec2 v_screen_size = screen_size;
    vec2 tex_size = vec2(textureSize(image, 0));

    vec2 dest_size = tex_size;
    uint fit = info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float s = min(v_screen_size.x / tex_size.x, v_screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        float s = max(v_screen_size.x / tex_size.x, v_screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = v_screen_size;
    }
    // else BG_IMAGE_NO_FIT: use original texture size

    vec2 start = vec2(0.0);
    vec2 mid = (v_screen_size - dest_size) / vec2(2.0);
    vec2 end = v_screen_size - dest_size;

    vec2 dest_offset = mid;
    uint pos = info & BG_IMAGE_POSITION;
    if (pos == BG_IMAGE_TL) {
        dest_offset = vec2(start.x, start.y);
    } else if (pos == BG_IMAGE_TC) {
        dest_offset = vec2(mid.x, start.y);
    } else if (pos == BG_IMAGE_TR) {
        dest_offset = vec2(end.x, start.y);
    } else if (pos == BG_IMAGE_ML) {
        dest_offset = vec2(start.x, mid.y);
    } else if (pos == BG_IMAGE_MC) {
        dest_offset = vec2(mid.x, mid.y);
    } else if (pos == BG_IMAGE_MR) {
        dest_offset = vec2(end.x, mid.y);
    } else if (pos == BG_IMAGE_BL) {
        dest_offset = vec2(start.x, end.y);
    } else if (pos == BG_IMAGE_BC) {
        dest_offset = vec2(mid.x, end.y);
    } else if (pos == BG_IMAGE_BR) {
        dest_offset = vec2(end.x, end.y);
    }

    v_offset = dest_offset;
    v_scale = tex_size / dest_size;

    // We load a fully opaque version of the bg color
    uvec4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    bg_color = vec4(load_color(
                uvec4(u_bg_color.rgb, 255u),
                use_linear_blending
            ).rgb, float(u_bg_color.a) / 255.0);
}
