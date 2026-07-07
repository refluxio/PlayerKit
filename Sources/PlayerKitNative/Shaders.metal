#include <metal_stdlib>
using namespace metal;

constant float PQ_m1 = 0.1593017578125;
constant float PQ_m2 = 78.84375;
constant float PQ_c1 = 0.8359375;
constant float PQ_c2 = 18.8515625;
constant float PQ_c3 = 18.6875;

// PQ EOTF: perceptual quantizer → linear
float pq_to_linear(float x) {
    float xp = pow(max(x, 0.0), 1.0 / PQ_m2);
    float num = max(xp - PQ_c1, 0.0);
    float den = PQ_c2 - PQ_c3 * xp;
    return pow(num / max(den, 0.0001), 1.0 / PQ_m1);
}

float3 pq_to_linear(float3 rgb) {
    return float3(pq_to_linear(rgb.r), pq_to_linear(rgb.g), pq_to_linear(rgb.b));
}

// HLG OOTF: hybrid log-gamma → linear (BT.2100)
float hlg_ootf(float x) {
    float a = 0.17883277;
    float b = 1.0 - 4.0 * a;
    float c = 0.5 - a * log(4.0 * a);
    if (x <= 1.0 / 12.0) {
        return sqrt(3.0 * x);
    } else {
        return a * log(12.0 * x - b) + c;
    }
}

float3 hlg_to_linear(float3 rgb) {
    return float3(hlg_ootf(rgb.r), hlg_ootf(rgb.g), hlg_ootf(rgb.b));
}

// BT.2020 → BT.709 matrix
constant float3x3 bt2020_to_bt709 = float3x3(
    float3( 1.6605, -0.5876, -0.0728),
    float3(-0.1246,  1.1329, -0.0083),
    float3(-0.0182, -0.1006,  1.1187)
);

// Simplified BT.2390 EETF: tone-map HDR linear → SDR linear
float bt2390_eetf(float x) {
    float peak = 100.0;  // input peak nits
    float target = 1.0;  // output peak (SDR = 1.0)
    float xp = x / peak;
    float s = peak / target;
    return xp < 0.0001 ? 0.0 : xp / sqrt(1.0 + s * s * xp * xp) * target;
}

float3 bt2390_eetf(float3 rgb) {
    float luma = dot(rgb, float3(0.2627, 0.6780, 0.0593));
    if (luma < 0.0001) return float3(0.0);
    float s = bt2390_eetf(luma) / luma;
    return rgb * s;
}

// Combined kernel: HDR → SDR
kernel void hdr_to_sdr(texture2d<float, access::read>  inTexture  [[texture(0)]],
                        texture2d<float, access::write> outTexture [[texture(1)]],
                        constant int &transfer [[buffer(0)]],   // 0=PQ, 1=HLG
                        constant bool &doColorMatrix [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;

    float3 rgb = inTexture.read(gid).rgb;

    // Step 1: transfer → linear
    if (transfer == 0) {
        rgb = pq_to_linear(rgb);
    } else if (transfer == 1) {
        rgb = hlg_to_linear(rgb);
    }

    // Step 2: tone-map (BT.2390)
    rgb = bt2390_eetf(rgb);

    // Step 3: gamut conversion (if needed)
    if (doColorMatrix) {
        rgb = bt2020_to_bt709 * rgb;
    }

    // Step 4: clamp
    rgb = clamp(rgb, 0.0, 1.0);

    outTexture.write(float4(rgb, 1.0), gid);
}
