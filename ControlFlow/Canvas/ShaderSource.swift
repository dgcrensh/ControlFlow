/// Metal shaders, compiled at launch from source so the project needs no .metal
/// build step. Struct layouts must match `CanvasUniforms` and `PaintUniforms`
/// (CanvasRenderer.swift), `CapsuleTessellator` and `ArtBatch` (ControlFlowCore).
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 worldToClip;
        float3x3 pixelToWorld;
        float worldPerPixel;
        float gridSpacing;
        float worldPerPoint;
        float padding;
        float4 background;
        float4 gridColor;
    };

    // 12 floats per vertex, see CapsuleTessellator. `flags` is 1 when `radius` is in
    // screen points (the editing overlay) and 0 when it is in world units (ink).
    struct StrokeVertex {
        packed_float2 a;
        packed_float2 b;
        packed_float2 corner;
        float radius;
        float flags;
        packed_float4 color;
    };

    struct StrokeOut {
        float4 position [[position]];
        float2 world;
        float2 a [[flat]];
        float2 b [[flat]];
        float radius [[flat]];
        float4 color [[flat]];
    };

    vertex StrokeOut stroke_vertex(uint vid [[vertex_id]],
                                   const device StrokeVertex *vertices [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
        StrokeVertex v = vertices[vid];
        float2 a = float2(v.a);
        float2 b = float2(v.b);
        float2 corner = float2(v.corner);
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-6 ? d / len : float2(1.0, 0.0);
        float2 normal = float2(-dir.y, dir.x);
        // A screen-space radius follows the zoom, so it is the same size on screen at
        // any zoom. The fragment shader gets the scaled radius.
        float radius = v.flags != 0.0 ? v.radius * u.worldPerPoint : v.radius;
        // Grow the quad past the capsule by a pixel and a half for anti-aliasing.
        float extent = radius + u.worldPerPixel * 1.5;
        float2 end = corner.x < 0.0 ? a - dir * extent : b + dir * extent;
        float2 world = end + normal * (corner.y * extent);

        StrokeOut out;
        out.position = u.worldToClip * float4(world, 0.0, 1.0);
        out.world = world;
        out.a = a;
        out.b = b;
        out.radius = radius;
        out.color = float4(v.color);
        return out;
    }

    fragment float4 stroke_fragment(StrokeOut in [[stage_in]]) {
        float2 pa = in.world - in.a;
        float2 ba = in.b - in.a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12), 0.0, 1.0);
        float dist = length(pa - ba * h);
        float aa = max(fwidth(dist), 1e-6);
        float coverage = saturate((in.radius - dist) / aa + 0.5);
        if (coverage <= 0.0) {
            discard_fragment();
        }
        return in.color * coverage; // premultiplied
    }

    // The art is drawn with stencil-then-cover (see ArtBuilder): triangles mark the
    // stencil, then a cover rectangle paints where the stencil test passes.
    struct FillOut {
        float4 position [[position]];
        // The vertex as the art gives it, before its place, layer and drag transforms:
        // gradients and pictures are in this space, so they move with the shape.
        float2 world;
    };

    vertex FillOut fill_vertex(uint vid [[vertex_id]],
                               const device packed_float2 *positions [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]]) {
        float2 world = float2(positions[vid]);
        FillOut out;
        out.position = u.worldToClip * float4(world, 0.0, 1.0);
        out.world = world;
        return out;
    }

    fragment float4 stencil_fragment() {
        return float4(0.0); // color writes are off
    }

    // A solid color or a gradient, in straight alpha. See PaintUniforms.
    struct Paint {
        float4 color;
        float4 points;      // start.xy, end.xy (in the vertices' space)
        float4 info;        // kind (0 solid, 1 linear, 2 radial), stop count, opacity
        float4 stopColors[8];
        float4 stopOffsets[2];
    };

    float stop_offset(constant Paint &paint, int i) {
        return paint.stopOffsets[i / 4][i % 4];
    }

    fragment float4 fill_fragment(FillOut in [[stage_in]], constant Paint &paint [[buffer(0)]]) {
        float4 c = paint.color;
        int kind = int(paint.info.x);
        if (kind != 0) {
            float2 s = paint.points.xy;
            float2 axis = paint.points.zw - s;
            float t = 0.0;
            if (kind == 1) {
                float len2 = dot(axis, axis);
                t = len2 > 1e-12 ? dot(in.world - s, axis) / len2 : 0.0;
            } else {
                float radius = length(axis);
                t = radius > 1e-6 ? length(in.world - s) / radius : 0.0;
            }
            t = saturate(t);
            int n = clamp(int(paint.info.y), 1, 8);
            c = paint.stopColors[n - 1];
            if (t <= stop_offset(paint, 0)) {
                c = paint.stopColors[0];
            } else {
                for (int i = 1; i < n; i++) {
                    float b = stop_offset(paint, i);
                    if (t <= b) {
                        float a = stop_offset(paint, i - 1);
                        float k = b - a > 1e-6 ? (t - a) / (b - a) : 1.0;
                        c = mix(paint.stopColors[i - 1], paint.stopColors[i], k);
                        break;
                    }
                }
            }
        }
        float alpha = c.a * paint.info.z;
        return float4(c.rgb * alpha, alpha); // premultiplied
    }

    // An image shape's picture, painted by a cover step in place of a fill. See
    // ImagePaintUniforms: each texture coordinate is a row of the world-to-image map.
    struct ImagePaint {
        float4 u;           // a, c, tx of the map's first row
        float4 v;           // b, d, ty of its second row
        float4 info;        // opacity
    };

    fragment float4 image_cover_fragment(FillOut in [[stage_in]],
                                         texture2d<float> image [[texture(0)]],
                                         sampler imageSampler [[sampler(0)]],
                                         constant ImagePaint &paint [[buffer(0)]]) {
        float2 uv = float2(dot(paint.u.xy, in.world) + paint.u.z, dot(paint.v.xy, in.world) + paint.v.z);
        return image.sample(imageSampler, uv) * saturate(paint.info.x); // premultiplied texels
    }

    struct ImageVertex {
        packed_float2 world;
        packed_float2 uv;
    };

    struct ImageOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex ImageOut image_vertex(uint vid [[vertex_id]],
                                 const device ImageVertex *vertices [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        ImageVertex v = vertices[vid];
        ImageOut out;
        out.position = u.worldToClip * float4(float2(v.world), 0.0, 1.0);
        out.uv = float2(v.uv);
        return out;
    }

    fragment float4 image_fragment(ImageOut in [[stage_in]],
                                   texture2d<float> image [[texture(0)]],
                                   sampler imageSampler [[sampler(0)]],
                                   constant float &opacity [[buffer(0)]]) {
        return image.sample(imageSampler, in.uv) * opacity; // premultiplied texels
    }

    struct GridOut {
        float4 position [[position]];
    };

    // One triangle that covers the whole screen.
    vertex GridOut grid_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        GridOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Dot grid over the infinite canvas, so pan, zoom and rotation are visible.
    fragment float4 grid_fragment(GridOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 world = (u.pixelToWorld * float3(in.position.xy, 1.0)).xy;
        float2 cell = world / u.gridSpacing;
        float2 offset = (cell - round(cell)) * u.gridSpacing;
        float distPx = length(offset) / u.worldPerPixel;
        float dotRadiusPx = 1.5;
        // The world origin gets a larger dot.
        if (all(round(cell) == float2(0.0))) {
            dotRadiusPx = 4.0;
        }
        float alpha = saturate(dotRadiusPx + 0.5 - distPx) * u.gridColor.a;
        return float4(mix(u.background.rgb, u.gridColor.rgb, alpha), 1.0);
    }
    """
}
