#include "common.glsl"

// OpenGL ES does not support layout(origin_upper_left).
// We flip Y using screen_size.

layout(binding = 0) uniform sampler2D image;

flat in vec4 bg_color;
flat in vec2 v_offset;
flat in vec2 v_scale;
flat in float opacity;
flat in uint v_repeat;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;

    // Flip Y: ES gl_FragCoord has origin at bottom-left
    vec2 frag_coord = vec2(gl_FragCoord.x, screen_size.y - gl_FragCoord.y);

    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size.
    vec2 tex_coord = (frag_coord - v_offset) * v_scale;

    vec2 tex_size = vec2(textureSize(image, 0));

    // If we need to repeat the texture, wrap the coordinates.
    if (v_repeat != 0u) {
        tex_coord = mod(mod(tex_coord, tex_size) + tex_size, tex_size);
    }

    vec4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(lessThan(tex_coord, vec2(0.0))) ||
            any(greaterThan(tex_coord, tex_size)))
    {
        rgba = vec4(0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        rgba = texture(image, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize_vec4(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity
    rgba *= min(opacity, 1.0 / bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(vec4(0.0), vec4(bg_color.rgb, 1.0) * vec4(1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= bg_color.a;

    out_FragColor = rgba;
}
