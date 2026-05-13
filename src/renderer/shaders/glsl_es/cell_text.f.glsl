#include "common.glsl"

// OpenGL ES: use sampler2D instead of sampler2DRect.
// Texture coordinates must be normalized (0.0 - 1.0).
layout(binding = 0) uniform sampler2D atlas_grayscale;
layout(binding = 1) uniform sampler2D atlas_color;

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0u;

    // Normalize texture coordinates for sampler2D
    vec2 tex_coord_gs = in_data.tex_coord / vec2(textureSize(atlas_grayscale, 0));
    vec2 tex_coord_color = in_data.tex_coord / vec2(textureSize(atlas_color, 0));

    if (in_data.atlas == ATLAS_COLOR) {
        // For now, we assume that color glyphs
        // are already premultiplied linear colors.
        vec4 color = texture(atlas_color, tex_coord_color);

        // If we are doing linear blending, we can return this right away.
        if (use_linear_blending) {
            out_FragColor = color;
            return;
        }

        // Otherwise we need to unlinearize the color. Since the alpha is
        // premultiplied, we need to divide it out before unlinearizing.
        color.rgb /= vec3(color.a);
        color = unlinearize_vec4(color);
        color.rgb *= vec3(color.a);

        out_FragColor = color;
        return;
    }

    // Default: ATLAS_GRAYSCALE
    {
        // Our input color is always linear.
        vec4 color = in_data.color;

        // If we're not doing linear blending, then we need to
        // re-apply the gamma encoding to our color manually.
        if (!use_linear_blending) {
            color.rgb /= vec3(color.a);
            color = unlinearize_vec4(color);
            color.rgb *= vec3(color.a);
        }

        // Fetch our alpha mask for this pixel.
        float a = texture(atlas_grayscale, tex_coord_gs).r;

        // Linear blending weight correction
        if (use_linear_correction) {
            vec4 bg = in_data.bg_color;
            float fg_l = luminance(color.rgb);
            float bg_l = luminance(bg.rgb);
            if (abs(fg_l - bg_l) > 0.001) {
                float blend_l = linearize_float(unlinearize_float(fg_l) * a + unlinearize_float(bg_l) * (1.0 - a));
                a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
            }
        }

        // Multiply our whole color by the alpha mask.
        color *= a;

        out_FragColor = color;
        return;
    }
}
