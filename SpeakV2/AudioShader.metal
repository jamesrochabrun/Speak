//
//  AudioShader.metal
//  SpeakV2
//
//  Created by James Rochabrun on 11/9/25.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };

    float2 texCoords[6] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment shader for audio-reactive circle
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant float &audioLevel [[buffer(0)]],
                               constant float &time [[buffer(1)]]) {
    // Center the coordinates
    float2 uv = in.texCoord * 2.0 - 1.0;
    uv.y *= -1.0; // Flip Y coordinate

    float dist = length(uv);

    // Base circle parameters
    float baseRadius = 0.3;
    float audioRadius = baseRadius + (audioLevel * 0.4);

    // Create pulsing effect with time
    float pulse = sin(time * 2.0) * 0.05;
    float radius = audioRadius + pulse;

    // Create smooth circle edge
    float circle = smoothstep(radius + 0.02, radius, dist);

    // Add glow effect
    float glow = exp(-dist * 2.0) * audioLevel * 0.5;

    // Create ring effect based on audio
    float ringWidth = 0.1 + audioLevel * 0.2;
    float ring = smoothstep(radius - ringWidth, radius - ringWidth + 0.02, dist) -
                 smoothstep(radius + 0.02, radius, dist);

    // Color scheme - gradient from blue to purple
    float3 centerColor = float3(0.4, 0.6, 1.0);  // Light blue
    float3 edgeColor = float3(0.8, 0.4, 1.0);    // Purple
    float3 glowColor = float3(0.6, 0.8, 1.0);    // Bright blue

    // Mix colors based on distance and audio level
    float colorMix = dist / radius;
    float3 baseColor = mix(centerColor, edgeColor, colorMix);

    // Combine circle, ring, and glow
    float3 finalColor = baseColor * circle;
    finalColor += edgeColor * ring * (1.0 + audioLevel);
    finalColor += glowColor * glow;

    // Add some sparkle effect based on audio
    float sparkle = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    if (sparkle > (1.0 - audioLevel * 0.3) && dist < radius) {
        finalColor += float3(1.0) * 0.3;
    }

    // Final alpha
    float alpha = circle + glow + ring;

    return float4(finalColor, min(alpha, 1.0));
}
