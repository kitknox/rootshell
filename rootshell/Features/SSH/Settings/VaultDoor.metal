//
//  VaultDoor.metal
//  rootshell
//
//  Saved Passwords header: a raymarched vault door set into a wall the color
//  of the row it sits on. The door unlocks, swings open onto a golden hash
//  mark, then closes and locks again. Everything is a function of `seq`,
//  the seconds since the sequence started; outside it the door is shut.
//

#include <metal_stdlib>
using namespace metal;

namespace vault {

struct State {
    float wheel;   // handle rotation, radians
    float lock;    // 1 = bolts thrown
    float open;    // 0 shut ... 1 fully swung
    float glow;    // interior light
    float present; // the hash mark turning to face out
    float glint;   // 0 ... 1 as a highlight sweeps across it
    float bob;     // hash mark float, scene units
};

constant float sequenceEnd = 7.2;
constant float3 hinge = float3(1.28, 0.0, 0.24);
constant float swing = 1.35;
// Contains the door at full swing, the collar and the hash mark.
constant float3 boundCenter = float3(0.4, 0.0, 0.6);
constant float boundRadius = 2.15;
constant float3 lightDir = float3(-0.44684, 0.56870, 0.69057);  // normalize(-0.55, 0.7, 0.85)
constant float3 interiorLight = float3(0.0, 0.3, -0.35);
constant float3 interiorColor = float3(1.0, 0.72, 0.4);
constant float3 hashCenter = float3(0.0, 0.02, -0.5);
constant float3 gold = float3(1.0, 0.76, 0.33);

static float ease(float t, float a, float b) {
    float x = clamp((t - a) / (b - a), 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

static float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

static float box(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

static float roundBox(float3 p, float3 b, float r) { return box(p, b - r) - r; }

static float cylinder(float2 radial, float axial, float r, float h) {
    float2 d = abs(float2(length(radial), axial)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

static float capsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

static float torusZ(float3 p, float R, float r) { return length(float2(length(p.xy) - R, p.z)) - r; }

static State stateAt(float seq) {
    float t = clamp(seq, 0.0, sequenceEnd);
    State s;
    s.wheel = -2.4 * ease(t, 0.2, 1.4) + 2.4 * ease(t, 5.9, 6.7);
    s.lock = 1.0 - ease(t, 1.3, 1.7) + ease(t, 6.6, 6.9);
    s.open = ease(t, 1.8, 3.0) - ease(t, 4.9, 6.0);
    s.glow = ease(t, 1.9, 2.8) - ease(t, 5.2, 6.0);
    s.present = ease(t, 2.2, 3.4) - ease(t, 4.8, 5.8);
    s.glint = ease(t, 3.3, 4.3);
    s.bob = 0.018 * sin(t * 2.2) * s.glow;
    return s;
}

// Into the hash mark's own frame: it starts turned away and swings round
/// to face out (slightly toward the camera) as the door opens.
static float3 hashSpace(float3 p, State s) {
    float3 q = p - hashCenter - float3(0.0, s.bob, 0.1 * s.present);
    q.xz = rot(mix(1.1, -0.22, s.present)) * q.xz;
    return q;
}

/// The rootshell #: two bars across, two leaning bars up, like the app icon.
static float hashMark(float3 q) {
    float across = roundBox(float3(q.x, abs(q.y) - 0.17, q.z), float3(0.47, 0.075, 0.09), 0.032);
    float3 v = q;
    v.x -= v.y * 0.24;
    v.x = abs(v.x) - 0.16;
    float up = roundBox(v, float3(0.075, 0.5, 0.09), 0.032) * 0.97;
    return min(across, up);
}

/// Material ids: 0 wall, 1 door steel, 2 dark steel, 3 gold, 4 chrome.
static float map(float3 p, State s, thread float &mat) {
    mat = 0;
    float bound = length(p - boundCenter) - boundRadius;
    if (bound > 0.05) return min(p.z, bound);

    float hole = max(length(p.xy) - 1.06, -(p.z + 0.9));
    float d = max(p.z, -hole);

    float2 cq = float2(length(p.xy) - 1.15, p.z - 0.14);
    float collar = length(max(abs(cq) - float2(0.08, 0.2), 0.0)) - 0.03;
    if (collar < d) { d = collar; mat = 2; }

    if (s.open > 0.0) {
        float mark = hashMark(hashSpace(p, s));
        if (mark < d) { d = mark; mat = 3; }
    }

    float3 q = p - hinge;
    q.xz = rot(s.open * swing) * q.xz;
    q += hinge;

    float body = min(cylinder(q.xy, q.z - 0.16, 0.96, 0.14) - 0.035,
                     cylinder(q.xy, q.z + 0.12, 0.88, 0.2) - 0.02);
    float grooves = min(torusZ(q - float3(0, 0, 0.335), 0.8, 0.02),
                        torusZ(q - float3(0, 0, 0.335), 0.52, 0.016));
    body = max(body, -grooves);
    if (body < d) { d = body; mat = 1; }

    float3 hq = q - hinge;
    hq.y = abs(hq.y) - 0.48;
    float barrel = cylinder(hq.xz, hq.y, 0.07, 0.13) - 0.01;
    float arm = roundBox(q - float3(1.08, sign(q.y) * 0.48, 0.22), float3(0.2, 0.06, 0.035), 0.015);
    if (min(barrel, arm) < d) { d = min(barrel, arm); mat = 2; }

    // Eight bolts, folded into one sector.
    float3 lq = q - float3(0, 0, 0.35);
    const float sector = 2.0 * M_PI_F / 8.0;
    float k = round((atan2(lq.y, lq.x) - sector * 0.5) / sector);
    lq.xy = rot(-(k * sector + sector * 0.5)) * lq.xy;
    float r0 = 0.7 + 0.24 * s.lock;
    float guide = roundBox(lq - float3(0.86, 0, -0.005), float3(0.07, 0.065, 0.02), 0.01);
    if (guide < d) { d = guide; mat = 2; }
    float bolt = capsule(lq, float3(r0, 0, 0), float3(r0 + 0.22, 0, 0), 0.042);
    if (bolt < d) { d = bolt; mat = 4; }

    float hub = cylinder(q.xy, q.z - 0.37, 0.19, 0.05) - 0.015;
    if (hub < d) { d = hub; mat = 4; }
    float3 wq = q - float3(0, 0, 0.48);
    wq.xy = rot(s.wheel) * wq.xy;
    const float spokeSector = 2.0 * M_PI_F / 3.0;
    wq.xy = rot(-round(atan2(wq.y, wq.x) / spokeSector) * spokeSector) * wq.xy;
    float wheel = min(min(capsule(wq, float3(0), float3(0.46, 0, 0), 0.032),
                          length(wq - float3(0.5, 0, 0)) - 0.06),
                      length(q - float3(0, 0, 0.48)) - 0.075);
    if (wheel < d) { d = wheel; mat = 4; }
    return d;
}

static bool hitsBound(float3 ro, float3 rd) {
    float3 oc = ro - boundCenter;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - boundRadius * boundRadius;
    float h = b * b - c;
    return h > 0.0 && (-b + sqrt(h)) > 0.0;
}

static float3 normalAt(float3 p, State s) {
    const float h = 0.0008;
    const float2 k = float2(1, -1);
    float m;
    return normalize(k.xyy * map(p + k.xyy * h, s, m) + k.yyx * map(p + k.yyx * h, s, m) +
                     k.yxy * map(p + k.yxy * h, s, m) + k.xxx * map(p + k.xxx * h, s, m));
}

static float softShadow(float3 ro, State s) {
    if (!hitsBound(ro, lightDir)) return 1.0;
    float res = 1.0, t = 0.02, previous = 1e10, m;
    for (int i = 0; i < 48 && t < 4.0; i++) {
        float3 p = ro + lightDir * t;
        // Outside the bound `map` returns a stand-in distance that would read as
        // a near miss, so only step there.
        float outside = length(p - boundCenter) - boundRadius;
        if (outside > 0.05) { t += outside; previous = 1e10; continue; }
        float h = map(p, s, m);
        float y = h * h / (2.0 * previous);
        float d = sqrt(max(h * h - y * y, 0.0));
        res = min(res, 8.0 * d / max(t - y, 1e-4));
        previous = h;
        if (res < 0.002) break;
        t += clamp(h, 0.006, 0.2);
    }
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res);
}

static float occlusion(float3 p, float3 n, State s) {
    float occ = 0.0, w = 1.0, m;
    for (int i = 1; i <= 5; i++) {
        float h = 0.025 * float(i);
        occ += (h - map(p + n * h, s, m)) * w;
        w *= 0.7;
    }
    return clamp(1.0 - 3.5 * occ, 0.0, 1.0);
}

static float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
static float3 toEncoded(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

// The wall's gentle light falloff bands in 8 bits without this.
static float3 dithered(float3 c, float2 position) {
    float2 q = floor(position * 3.0);
    float n = fract(sin(dot(q, float2(12.9898, 78.233))) * 43758.5453)
            + fract(sin(dot(q, float2(39.346, 11.135))) * 24634.6345) - 1.0;
    return c + n / 255.0;
}

static float3 softClip(float3 c) {
    float3 over = max(c - 0.8, 0.0);
    return min(c, 0.8) + 0.2 * (1.0 - exp(-over / 0.2));
}

} // namespace vault

/// - position, size: points, as SwiftUI passes them.
/// - center: where the door sits. artHeight: points the scene's height maps to,
///   so taller text grows the banner without zooming the door.
/// - surface, accent: the row color and accent the wall and metal are tinted by.
[[ stitchable ]] half4 vaultDoor(
    float2 position,
    half4 color,
    float2 center,
    float artHeight,
    float seq,
    half4 surfaceColor,
    half4 accentColor,
    float isLight
) {
    using namespace vault;
    State s = stateAt(seq);
    bool light = isLight > 0.5;
    float3 surface = float3(surfaceColor.rgb);
    float3 accent = toLinear(float3(accentColor.rgb));
    float3 wallBase = toLinear(mix(surface, float3(accentColor.rgb), light ? 0.03 : 0.04));

    float drift = 0.06 * sin(clamp(seq, 0.0, sequenceEnd) / sequenceEnd * M_PI_F);
    float3 ro = float3(-1.2 + drift, 0.55, 4.6);
    float3 fw = normalize(float3(0.25, 0.0, 0.0) - ro);
    float3 rt = normalize(cross(fw, float3(0, 1, 0)));
    float3 up = cross(rt, fw);
    float2 uv = (position - center) / artHeight;
    uv.y = -uv.y;
    float3 rd = normalize(rt * uv.x + up * uv.y + fw * 1.4);

    float t = 0.0, mat = 0.0;
    bool inBound = hitsBound(ro, rd);
    if (inBound) {
        t = 0.5;
        bool hit = false;
        for (int i = 0; i < 110; i++) {
            float h = map(ro + rd * t, s, mat);
            if (h < 0.0006 * t) { hit = true; break; }
            t += h * 0.9;
            if (t > 12.0) break;
        }
        if (!hit) return half4(half3(dithered(toEncoded(wallBase), position)), 1);
    } else {
        // Plain wall: the plane z = 0, flat and unoccluded.
        if (rd.z >= 0.0) return half4(half3(dithered(toEncoded(wallBase), position)), 1);
        t = -ro.z / rd.z;
    }

    float3 p = ro + rd * t;
    float3 n = inBound ? normalAt(p, s) : float3(0, 0, 1);
    float3 v = -rd;
    float sh = softShadow(p + n * 0.003, s);
    // Its samples reach 0.125 out; keep them where `map` is exact.
    float ao = length(p - boundCenter) < boundRadius - 0.2 ? occlusion(p, n, s) : 1.0;
    float diff = max(dot(n, lightDir), 0.0);

    float3 col;
    if (mat < 0.5) {
        float spot = exp(-dot(p.xy, p.xy) * 0.6);
        float lit = diff * sh * spot;
        float gain = light ? mix(1.0, 1.05, lit) : mix(1.0, 1.45, lit);
        col = wallBase * gain * mix(0.5, 1.0, ao) * mix(light ? 0.86 : 0.62, 1.0, sh);
        if (p.z < -0.05) {
            float3 ld = interiorLight - p;
            float fall = 1.0 / (1.0 + dot(ld, ld) * 6.0);
            col = col * mix(0.35, 1.0, ao) * (light ? 0.55 : 0.8) + interiorColor * s.glow * fall * 1.6;
        }
    } else {
        float3 albedo;
        float rough;
        if (mat < 1.5) { albedo = mix(float3(0.6, 0.61, 0.63), accent, 0.06); rough = 0.3; }
        else if (mat < 2.5) { albedo = mix(float3(0.16, 0.16, 0.18), accent, 0.12); rough = 0.42; }
        else if (mat < 3.5) { albedo = gold; rough = 0.2; }
        else { albedo = float3(0.88, 0.89, 0.92); rough = 0.12; }

        float sparkle = 0.0;
        if (mat > 2.5 && mat < 3.5) {
            // A bright band crossing the mark once, after it turns to face out.
            float3 h = hashSpace(p, s);
            float sweep = mix(-0.9, 0.9, s.glint);
            sparkle = smoothstep(0.09, 0.0, abs(h.x + h.y * 0.5 - sweep)) * sin(s.glint * M_PI_F);
        }
        if (mat < 1.5) {
            // Turned finish on the door face.
            float3 q = p - hinge;
            q.xz = rot(s.open * swing) * q.xz;
            q += hinge;
            // Fades out before its rings get finer than a couple of pixels.
            float footprint = t / (1.4 * artHeight);
            albedo *= 1.0 - 0.035 * sin(length(q.xy) * 100.0) * (1.0 - smoothstep(0.6, 1.0, footprint * 100.0 / 6.2832));
        }

        float3 envTop = light ? mix(float3(1.0), accent, 0.25) * 1.25 : mix(toLinear(surface), accent, 0.18) * 1.7 + 0.04;
        float3 envBottom = light ? toLinear(surface) * 0.45 : toLinear(surface) * 0.16;
        float3 r = reflect(rd, n);
        float3 env = mix(envBottom, envTop, smoothstep(-0.4, 0.7, r.y));
        float3 softbox = normalize(float3(-0.45, 0.65, 0.6));
        env += pow(max(dot(r, softbox), 0.0), 2.0 / (rough * rough + 0.01)) * (light ? 1.8 : 3.2);
        // Inside the vault the gold sees the warm interior, not the room.
        if (mat > 2.5 && mat < 3.5) env = mix(env, interiorColor * 1.3 + 0.15, 0.65 * s.glow);

        float nv = max(dot(n, v), 0.0);
        float3 fresnel = albedo + (1.0 - albedo) * pow(1.0 - nv, 5.0);
        float3 hv = normalize(lightDir + v);
        float specPower = min(2.0 / (rough * rough * rough + 0.0008), 2000.0);
        float spec = pow(max(dot(n, hv), 0.0), specPower) * (specPower + 8.0) / 25.0;
        col = fresnel * (env * ao * mix(0.55, 1.0, sh) + spec * sh * 1.4);
        col += albedo * diff * sh * 0.12;

        if (s.glow > 0.0) {
            float3 ld = interiorLight - p;
            float fall = 1.0 / (1.0 + dot(ld, ld) * 4.0);
            col += albedo * interiorColor * s.glow * fall * max(dot(n, normalize(ld)), 0.0) * 1.5;
        }
        col += gold * sparkle * 1.6 * s.glow;
    }

    return half4(half3(dithered(toEncoded(softClip(col)), position)), 1);
}
