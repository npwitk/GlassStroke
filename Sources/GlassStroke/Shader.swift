// The glass renderer's GPU code, compiled at run time.
//
// Each stroke is a round tube in 3D: a ball of the pen's radius swept along
// the centre line, lying in the z = 0 plane. Tubes are blended into one
// surface where they meet (a smooth minimum of their distance fields). Each
// pixel looks straight down the z axis: the ray is marched to the glass,
// refracted into it (a slightly different index for red, green and blue),
// marched through to the far side, refracted out, and continues far below to
// a blurred copy of the backdrop. A Fresnel reflection of the sharp backdrop
// and highlights from three lights go on top.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Segment { float4 a; float4 b; float4 ta; float4 tb; float4 range; };

struct Uniforms {
    float4 frame;      // width, height (px), units per px, supersampling (n x n)
    float4 transform;  // units = px * xy + zw (px y-up)
    float4 light;      // key light direction xyz, intensity
    float4 write;      // progress (0...1), blend radius, ray start z, segment count
    float4 glass;      // refraction distance, flatten, dispersion, edge softness (px)
    float4 tone;       // milk, absorption, reflection, specular
    float4 tiles;      // tile size (px), tiles x, tiles y, output mode (0 transparent, 1 over backdrop)
    float4 iors;       // index at the rim, index face-on, debug, -
    float4 shape;      // mode (0 strokes, 1 filled shape), thickness scale, units per texel, pen reach (0: all)
    float4 shapeMap;   // units of texel (0, 0) (bottom-left) xy, texture size zw
};

constexpr sampler bg(address::clamp_to_edge, filter::linear);

static float3 hermite(constant Segment& s, float t) {
    float t2 = t * t, t3 = t2 * t;
    return (2*t3 - 3*t2 + 1) * s.a.xyz + (t3 - 2*t2 + t) * s.ta.xyz + (-2*t3 + 3*t2) * s.b.xyz + (t3 - t2) * s.tb.xyz;
}
static float3 hermite1(constant Segment& s, float t) {
    float t2 = t * t;
    return (6*t2 - 6*t) * s.a.xyz + (3*t2 - 4*t + 1) * s.ta.xyz + (-6*t2 + 6*t) * s.b.xyz + (3*t2 - 2*t) * s.tb.xyz;
}
static float3 hermite2(constant Segment& s, float t) {
    return (12*t - 6) * s.a.xyz + (6*t - 4) * s.ta.xyz + (-12*t + 6) * s.b.xyz + (6*t - 2) * s.tb.xyz;
}

// Distance from p to the segment's tube, as far as the pen has written it;
// y is 1 where the nearest point is inside the segment or on a pen end, the
// places where tubes may melt together.
static float2 sdSegment(float3 p, constant Segment& s, float progress) {
    if (progress <= s.range.x) return float2(1e9, 0);
    float span = s.range.y - s.range.x;
    float tmax = span > 0 ? clamp((progress - s.range.x) / span, 0.0, 1.0) : 1.0;
    float3 ab = s.b.xyz - s.a.xyz;
    float t0 = dot(p - s.a.xyz, ab) / max(dot(ab, ab), 1e-6);
    float t = clamp(t0, 0.0, tmax);
    for (int i = 0; i < 4; i++) {
        float3 q = hermite(s, t) - p, d1 = hermite1(s, t), d2 = hermite2(s, t);
        float f = dot(q, d1), fp = dot(d1, d1) + dot(q, d2);
        t0 = t - f / max(fp, 1e-4);
        t = clamp(t0, 0.0, tmax);
    }
    bool open = (t0 >= 0 && t0 <= tmax) || (s.range.z > 0 && t0 < 0) || (t0 > tmax && (tmax < 1 || s.range.w > 0));
    return float2(length(hermite(s, t) - p) - mix(s.a.w, s.b.w, t), open ? 1.0 : 0.0);
}

static float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * h * k / 6.0;
}

struct Ctx {
    constant Uniforms& U;
    constant Segment* segs;
    constant uint* list;
    uint count;
    texture2d<float> sdf;
};

constexpr sampler sdfSampler(address::clamp_to_edge, filter::linear);

// A filled shape as inflated glass: inside its outline, between -h and +h
// in z, where h is the inflated height (round across thin parts, a smooth
// dome over wide ones). Straight down the z axis this is an exact distance;
// sideways it's scaled down to stay a safe marching bound.
static float sdShape(float3 p, thread const Ctx& c) {
    constant Uniforms& U = c.U;
    float2 uv = (p.xy - U.shapeMap.xy) / U.shape.z / U.shapeMap.zw;
    float2 cl = clamp(uv, 0.0, 1.0);
    float4 f = c.sdf.sample(sdfSampler, float2(cl.x, 1.0 - cl.y));
    float d2 = f.x + length((uv - cl) * U.shapeMap.zw) * U.shape.z;   // beyond the texture
    float z = f.y * U.shape.y;
    if (U.shape.w > 0) {
        // written on: only what the pen has reached, ending in a round tip
        // (as wide as the glass there, like the end of a pen tube)
        float ahead = (f.z - U.shape.w) * f.w;         // > 0: not reached yet (as a distance)
        float r = max(z, 1.0);
        float into = -ahead;                           // how far behind the tip
        z = into >= r ? z : (into > 0 ? sqrt(max(0.0, r * r - (r - into) * (r - into))) * z / r : 0.0);
        float k = r;                                   // round the tip's corners
        float hh = max(k - abs(d2 - ahead), 0.0) / k;
        d2 = max(d2, ahead) + hh * hh * k * 0.25;
    }
    float slab = abs(p.z) - z;
    return max(d2, slab * 0.8);
}

static float scene(float3 p, thread const Ctx& c) {
    if (c.U.shape.x > 0.5) return sdShape(p, c);
    float hard = 1e9, soft = 1e9, k = c.U.write.y;
    for (uint i = 0; i < c.count; i++) {
        float2 e = sdSegment(p, c.segs[c.list[i]], c.U.write.x);
        hard = min(hard, e.x);
        if (e.y > 0) soft = k > 0 ? smin(soft, e.x, k) : min(soft, e.x);
    }
    return min(hard, soft);
}

static float3 normalAt(float3 p, thread const Ctx& c) {
    const float e = 0.25;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * scene(p + k.xyy * e, c) + k.yyx * scene(p + k.yyx * e, c) +
                     k.yxy * scene(p + k.yxy * e, c) + k.xxx * scene(p + k.xxx * e, c));
}

struct Hit { float t; float d; float3 p; float3 n; };

// side +1 marches outside the glass, -1 inside it
static Hit march(float3 ro, float3 rd, float side, thread const Ctx& c) {
    float t = 0, d = 0;
    float minStep = c.U.write.x >= 0.005 ? (side > 0 ? 0.4 : 0.1) : 0.02;
    for (int i = 0; i < 40; i++) {
        d = side * scene(ro + rd * t, c);
        if (d < 0.02 && t > 0.02) break;
        t += max(d, minStep);
    }
    Hit h; h.t = t; h.d = d; h.p = ro + rd * t;
    float3 n = normalAt(h.p, c);
    // a pillowy surface: normals pulled toward the viewer, most where the
    // glass faces it
    // rounder while the pen is just starting
    float wp = c.U.write.x, a5 = pow(wp, 5.0);
    float early = saturate((0.2 * (1.0 - a5) - wp) / (0.2 * (1.0 - a5) + 0.1 * a5));
    float w = pow(abs(n.z) * 0.9, c.U.glass.y + 3.0 * early) + 0.1;
    h.n = normalize(mix(n, float3(0, 0, sign(n.z)), w));
    return h;
}

static float2 uvAt(float2 q, constant Uniforms& U) {
    float2 px = (q - U.transform.zw) / U.transform.xy;
    return float2(px.x / U.frame.x, 1.0 - px.y / U.frame.y);
}

static float3 refractOr(float3 d, float3 n, float eta) {
    float3 r = refract(d, n, eta);
    return dot(r, r) > 0 ? r : reflect(d, n);
}

static float fresnel(float cosine) {
    return 0.33 + 0.67 * pow(1.0 - max(0.0, cosine), 6.0);
}

// The hello screen's grading of the light coming through the glass.
// c: refracted backdrop; seen: sharp backdrop where it lands; depth: path
// through the glass; lum: c's luminance; key: 1 - 0.6 x how much the surface
// faces away from the key light; facing: how much it faces the viewer.
static float3 tone(float3 c, float3 seen, float depth, float lum, float key, float facing) {
    float e = exp(-0.00125 * depth);
    float3 absorb = mix(float3(e), float3((e + 1.0) * 0.5), key);
    float s = saturate(facing);
    float3 base = mix(seen, c, s * s * (3.0 - 2.0 * s) * 0.5 + 0.5);
    float avg = dot(base, float3(1)) * 0.5 / 3.0;
    float bright = avg + 0.5;
    float cool = mix(1.0, 0.5, dot(base, float3(0, 1, 0.5)) / 1.25);
    float3 body = base * absorb * mix(1.0, facing, pow(lum, 0.75) * key);
    float key15 = pow(key, 1.5), away = 1.0 - key;
    float3 rimTint = float3((facing * 0.25 + 0.75) * 0.75 * (0.5 - avg) * cool) * (base + 1.0);
    float glow = pow(sin(M_PI_F * pow(lum, 0.35)), 2.0) * cool;
    float3 glowCol = float3(glow * 0.25) + (1.0 - pow(lum, 5.0)) * 0.25 * base;
    float3 lit = base * facing * 0.5;
    float3 v = body + away * 0.1 - (bright * 0.05 + away * glowCol) + (lit * glow + rimTint) * key15;
    v *= lit * 2.0 * glow * mix(key, 1.0, lum) + 1.0;
    v = mix(v, (base + 1.0) * 0.5, glow * 0.25 * key);
    float sparkle = pow(sin(M_PI_F * pow(lum, 1.25)), 3.0) * cool;
    v *= (1.0 - (1.0 - pow(key, 2.0 - lum)) * (lum * 0.25 + 0.5));
    v *= 1.0 - lit * sparkle * away;
    v *= lit * sparkle * key15 + 1.0;
    float3 sq = saturate(v);
    v = mix(v, sq * sq * (3.0 - 2.0 * sq), (1.0 - facing) * 0.5 * key15);
    v -= away * 0.25 * (1.0 - pow(lum, 0.25));
    v *= mix(1.0, pow(facing, 2.0 - lum), key);
    v *= (cool + 1.0) * 0.5 * (key15 * 0.75 + 0.25) * (1.0 - pow(lum, 4.0)) + 1.0;
    v -= ((sparkle + glow) * 0.125 + bright * 0.0625) * away;
    return v;
}

static float4 shade(float2 q, thread const Ctx& c, texture2d<float> blurred, texture2d<float> sharp) {
    constant Uniforms& U = c.U;
    float3 ro = float3(q, U.write.z), rd = float3(0, 0, 1);
    Hit h = march(ro, rd, 1.0, c);
    if (h.d > 0.02) return float4(sharp.sample(bg, uvAt(q, U)).rgb, 1);
    float3 n = h.n;
    float facing = max(0.0, -n.z);
    float ior = mix(U.iors.x, U.iors.y, facing);
    float disp = U.glass.z;
    // into the glass: green at the base index, red and blue either side
    float3 dG = refractOr(rd, n, 1.0 / ior);
    float3 dR = refractOr(rd, n, 1.0 / (ior * (1.0 - disp)));
    float3 dB = refractOr(rd, n, 1.0 / (ior * (1.0 + disp)));
    Hit in = march(h.p - n * 0.04, dG, -1.0, c);
    float3 n2 = -in.n;
    float3 eR = h.p + dR * in.t, eG = h.p + dG * in.t, eB = h.p + dB * in.t;
    float3 oR = refractOr(dR, n2, ior * (1.0 - disp));
    float3 oG = refractOr(dG, n2, ior);
    float3 oB = refractOr(dB, n2, ior * (1.0 + disp));
    float D = U.glass.x;
    if (U.iors.z > 0.5) return float4(facing, in.t / 400.0, saturate(-dot(U.light.xyz, n)), 1);
    float3 col = float3(blurred.sample(bg, uvAt(eR.xy + oR.xy * D, U)).r,
                        blurred.sample(bg, uvAt(eG.xy + oG.xy * D, U)).g,
                        blurred.sample(bg, uvAt(eB.xy + oB.xy * D, U)).b);
    float3 seen = sharp.sample(bg, uvAt(eG.xy + oG.xy * D, U)).rgb;
    float keyFacing = 1.0 - max(0.0, -dot(U.light.xyz, n)) * 0.6;
    col = tone(col, seen, in.t, dot(float3(0.299, 0.587, 0.114), col), keyFacing, facing);
    // reflection of the sharp backdrop
    float3 r = reflect(rd, n);
    float4 refl = float4(sharp.sample(bg, uvAt(h.p.xy + r.xy * D, U)).rgb,
                         fresnel(dot(r, n)) * pow(max(0.0, dot(rd, r)), 2.0) * U.tone.z);
    col = mix(col, refl.rgb, saturate(refl.a));
    // highlights: the key light, its opposite, and a fixed fill
    float3 L1 = U.light.xyz, L2 = -U.light.xyz, L3 = float3(0.8165, -0.4082, -0.4082);
    float I = U.light.w * U.tone.w;
    float spec = 0;
    float3 Ls[3] = {L1, L2, L3};
    float Is[3] = {3.0 * I, 1.5 * I, 0.3 * I * sqrt(max(0.0, 1.0 - abs(L1.y)))};
    for (int i = 0; i < 3; i++) {
        float3 R = 2.0 * dot(n, Ls[i]) * n - Ls[i];
        spec += pow(max(0.0, dot(R, rd)), 6.0) * Is[i] * fresnel(-dot(Ls[i], n));
    }
    col = mix(col, float3(1), saturate(spec));
    return float4(col, 1);
}

static float3 toSRGB(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

kernel void glassKernel(texture2d<float, access::write> out [[texture(0)]],
                        texture2d<float> blurred [[texture(1)]],
                        texture2d<float> sharp [[texture(2)]],
                        constant Uniforms& U [[buffer(0)]],
                        constant Segment* segs [[buffer(1)]],
                        constant uint* tileRanges [[buffer(2)]],
                        constant uint* tileItems [[buffer(3)]],
                        texture2d<float> sdf [[texture(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint W = uint(U.frame.x), H = uint(U.frame.y);
    if (gid.x >= W || gid.y >= H) return;
    float2 px = float2(gid.x + 0.5, H - gid.y - 0.5);         // y-up pixel centre
    uint tx = min(uint(px.x / U.tiles.x), uint(U.tiles.y) - 1), ty = min(uint(px.y / U.tiles.x), uint(U.tiles.z) - 1);
    uint ti = ty * uint(U.tiles.y) + tx;
    Ctx c = { U, segs, tileItems + tileRanges[2 * ti], tileRanges[2 * ti + 1], sdf };
    float3 back = sharp.sample(bg, float2(px.x / U.frame.x, 1.0 - px.y / U.frame.y)).rgb;
    float4 acc = 0;
    int n = int(U.frame.w);
    float upp = U.frame.z;
    for (int sy = 0; sy < n; sy++) for (int sx = 0; sx < n; sx++) {
        float2 sp = px + (float2(sx, sy) + 0.5) / float(n) - 0.5;
        float2 q = sp * U.transform.xy + U.transform.zw;
        float d2 = scene(float3(q, 0), c);
        float a = smoothstep(0.0, 1.0, saturate(-d2 / (upp * U.glass.w)));
        if (a > 0) {
            float3 col = shade(q, c, blurred, sharp).rgb;
            acc += float4(col * a, a);
        }
    }
    acc /= float(n * n);
    float4 o;
    if (U.tiles.w > 0.5) o = float4(acc.rgb + back * (1.0 - acc.a), 1.0);
    else o = float4(acc.a > 0 ? acc.rgb / acc.a : float3(0), acc.a);
    out.write(float4(toSRGB(o.rgb) * (U.tiles.w > 0.5 ? 1.0 : o.a), o.a), gid);
}
"""
