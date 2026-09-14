#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 shadowColor;
    vec4 lightColor;
    vec4 accentColor;
    float tintAmount;
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 sampleColor = texture(source, qt_TexCoord0);
    vec3 rgb = sampleColor.rgb / max(sampleColor.a, 0.0001);
    float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 themed = mix(shadowColor.rgb, lightColor.rgb, luminance);
    // Keep the accent in midtones so shadows and highlights retain contrast.
    themed = mix(themed, accentColor.rgb, 0.2 * 4.0 * luminance * (1.0 - luminance));
    fragColor = vec4(mix(rgb, themed, tintAmount) * sampleColor.a, sampleColor.a) * qt_Opacity;
}
