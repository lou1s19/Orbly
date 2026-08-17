import AppKit
import MetalKit
import SwiftUI

/// Metal-Port des 21st.dev "Voice Powered Orb"-GLSL-Shaders.
/// Wird zur Laufzeit kompiliert (kein Metal-Toolchain beim Build noetig).
enum OrbShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float time;
        float mono;
        float2 resolution;
        float hue;
        float hover;
        float rot;
        float hoverIntensity;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut orb_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut o;
        o.position = float4(pos[vid], 0.0, 1.0);
        o.uv = (pos[vid] + 1.0) * 0.5;
        return o;
    }

    static float3 rgb2yiq(float3 c) {
        float y = dot(c, float3(0.299, 0.587, 0.114));
        float i = dot(c, float3(0.596, -0.274, -0.322));
        float q = dot(c, float3(0.211, -0.523, 0.312));
        return float3(y, i, q);
    }

    static float3 yiq2rgb(float3 c) {
        float r = c.x + 0.956 * c.y + 0.621 * c.z;
        float g = c.x - 0.272 * c.y - 0.647 * c.z;
        float b = c.x - 1.106 * c.y + 1.703 * c.z;
        return float3(r, g, b);
    }

    static float3 adjustHue(float3 color, float hueDeg) {
        float hueRad = hueDeg * 3.14159265 / 180.0;
        float3 yiq = rgb2yiq(color);
        float cosA = cos(hueRad);
        float sinA = sin(hueRad);
        float i = yiq.y * cosA - yiq.z * sinA;
        float q = yiq.y * sinA + yiq.z * cosA;
        yiq.y = i;
        yiq.z = q;
        return yiq2rgb(yiq);
    }

    static float3 hash33(float3 p3) {
        p3 = fract(p3 * float3(0.1031, 0.11369, 0.13787));
        p3 += dot(p3, p3.yxz + 19.19);
        return -1.0 + 2.0 * fract(float3(
            p3.x + p3.y,
            p3.x + p3.z,
            p3.y + p3.z
        ) * p3.zyx);
    }

    static float snoise3(float3 p) {
        const float K1 = 0.333333333;
        const float K2 = 0.166666667;
        float3 i = floor(p + (p.x + p.y + p.z) * K1);
        float3 d0 = p - (i - (i.x + i.y + i.z) * K2);
        float3 e = step(float3(0.0), d0 - d0.yzx);
        float3 i1 = e * (1.0 - e.zxy);
        float3 i2 = 1.0 - e.zxy * (1.0 - e);
        float3 d1 = d0 - (i1 - K2);
        float3 d2 = d0 - (i2 - K1);
        float3 d3 = d0 - 0.5;
        float4 h = max(0.6 - float4(
            dot(d0, d0), dot(d1, d1), dot(d2, d2), dot(d3, d3)
        ), 0.0);
        float4 n = h * h * h * h * float4(
            dot(d0, hash33(i)),
            dot(d1, hash33(i + i1)),
            dot(d2, hash33(i + i2)),
            dot(d3, hash33(i + 1.0))
        );
        return dot(float4(31.316), n);
    }

    static float4 extractAlpha(float3 colorIn) {
        float a = max(max(colorIn.r, colorIn.g), colorIn.b);
        return float4(colorIn.rgb / (a + 1e-5), a);
    }

    constant float3 baseColor1 = float3(0.611765, 0.262745, 0.996078);
    constant float3 baseColor2 = float3(0.298039, 0.760784, 0.913725);
    constant float3 baseColor3 = float3(0.062745, 0.078431, 0.600000);
    constant float innerRadius = 0.6;
    constant float noiseScale = 0.65;

    static float light1(float intensity, float attenuation, float dist) {
        return intensity / (1.0 + dist * attenuation);
    }

    static float light2(float intensity, float attenuation, float dist) {
        return intensity / (1.0 + dist * dist * attenuation);
    }

    static float4 drawOrb(float2 uv, constant Uniforms& u) {
        float3 color1 = adjustHue(baseColor1, u.hue);
        float3 color2 = adjustHue(baseColor2, u.hue);
        float3 color3 = adjustHue(baseColor3, u.hue);

        float ang = atan2(uv.y, uv.x);
        float len = length(uv);
        float invLen = len > 0.0 ? 1.0 / len : 0.0;

        float n0 = snoise3(float3(uv * noiseScale, u.time * 0.5)) * 0.5 + 0.5;
        float r0 = mix(mix(innerRadius, 1.0, 0.4), mix(innerRadius, 1.0, 0.6), n0);
        float d0 = distance(uv, (r0 * invLen) * uv);
        float v0 = light1(1.0, 10.0, d0);
        v0 *= smoothstep(r0 * 1.05, r0, len);
        float cl = cos(ang + u.time * 2.0) * 0.5 + 0.5;

        float a = u.time * -1.0;
        float2 pos = float2(cos(a), sin(a)) * r0;
        float d = distance(uv, pos);
        float v1 = light2(1.5, 5.0, d);
        v1 *= light1(1.0, 50.0, d0);

        float v2 = smoothstep(1.0, mix(innerRadius, 1.0, n0 * 0.5), len);
        float v3 = smoothstep(innerRadius, mix(innerRadius, 1.0, 0.5), len);

        float3 col = mix(color1, color2, cl);
        col = mix(color3, col, v0);
        col = (col + v1) * v2 * v3;
        col = clamp(col, 0.0, 1.0);

        return extractAlpha(col);
    }

    fragment float4 orb_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 fragCoord = in.uv * u.resolution;
        float2 center = u.resolution * 0.5;
        float size = min(u.resolution.x, u.resolution.y);
        float2 uv = (fragCoord - center) / size * 2.0;

        float s = sin(u.rot);
        float c = cos(u.rot);
        uv = float2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);

        uv.x += u.hover * u.hoverIntensity * 0.1 * sin(uv.y * 10.0 + u.time);
        uv.y += u.hover * u.hoverIntensity * 0.1 * sin(uv.x * 10.0 + u.time);

        float4 col = drawOrb(uv, u);
        // Mono-Variante: auf Luminanz reduzieren, leicht aufgehellt
        if (u.mono > 0.5) {
            float g = dot(col.rgb, float3(0.299, 0.587, 0.114));
            col.rgb = float3(pow(g, 0.85));
        }
        return float4(col.rgb * col.a, col.a);
    }
    """
}

struct OrbUniforms {
    var time: Float
    var mono: Float = 0
    var resolution: SIMD2<Float>
    var hue: Float
    var hover: Float
    var rot: Float
    var hoverIntensity: Float
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private let state: OverlayState
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var time: Float = 0
    private var rot: Float = 0
    private var hover: Float = 0
    private var lastDraw = CFAbsoluteTimeGetCurrent()

    init(state: OverlayState) {
        self.state = state
    }

    /// Einmal gebaute Pipeline, für die ganze Programmlaufzeit.
    ///
    /// `makeLibrary(source:)` kompiliert den Shader zur Laufzeit aus dem
    /// Quelltext, das kostet 30 bis 150 ms auf dem Hauptthread. Die MTKView wird
    /// aber jedes Mal ab- und wieder aufgebaut, wenn das Overlay verschwindet
    /// oder ein Hinweis erscheint. Ohne diesen Zwischenspeicher fiele die
    /// Kompilierung genau beim Fn-Druck an, also wenn das Overlay sofort da sein
    /// soll. `nil` = schon einmal versucht und fehlgeschlagen.
    private static var sharedPipeline: (pipeline: MTLRenderPipelineState, queue: MTLCommandQueue)?
    private static var setupFailed = false

    /// true, wenn die Pipeline steht. false heißt: Der Orb kann nicht gezeichnet
    /// werden (Aufrufer fällt dann auf den Pill-Stil zurück).
    @discardableResult
    func setup(device: MTLDevice) -> Bool {
        if let shared = Self.sharedPipeline {
            pipeline = shared.pipeline
            queue = shared.queue
            return true
        }
        guard !Self.setupFailed else { return false }
        do {
            let lib = try device.makeLibrary(source: OrbShader.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "orb_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "orb_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let builtPipeline = try device.makeRenderPipelineState(descriptor: desc)
            guard let builtQueue = device.makeCommandQueue() else {
                Self.setupFailed = true
                return false
            }
            Self.sharedPipeline = (builtPipeline, builtQueue)
            pipeline = builtPipeline
            queue = builtQueue
            return true
        } catch {
            Self.setupFailed = true
            NSLog("Orbly: Orb-Shader-Kompilierung fehlgeschlagen: \(error)")
            return false
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(now - lastDraw, 0.1))
        lastDraw = now

        var level = state.levels.last ?? 0
        if state.phase == .processing {
            level = 0.25 + 0.2 * Float(sin(now * 4.0))
        }
        let targetHover = min(level * 2.0, 1.0)
        hover += (targetHover - hover) * 0.25
        time += dt
        // wie in der Vorlage: Stimme beschleunigt die Rotation
        if level > 0.05 {
            rot += dt * (0.3 + level * 2.4)
        }

        var u = OrbUniforms(
            time: time,
            mono: state.style == .orbMono ? 1 : 0,
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            hue: 0,
            hover: hover,
            rot: rot,
            hoverIntensity: min(hover * 0.64, 0.8)
        )

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct OrbMetalView: NSViewRepresentable {
    @ObservedObject var state: OverlayState

    func makeCoordinator() -> OrbRenderer {
        OrbRenderer(state: state)
    }

    /// Gibt es kein Metal-Gerät oder scheitert die Shader-Kompilierung, würde die
    /// Orb-Ansicht dauerhaft leer bleiben - beim Diktieren wäre dann GAR KEIN
    /// Overlay zu sehen (orbMono ist der Standardstil) und die App wirkte tot.
    /// Dann auf den reinen SwiftUI-Stil „pill" zurückfallen.
    private static func fallBackToPill(_ reason: String) {
        NSLog("Orbly: Orb-Overlay nicht verfügbar (\(reason)) - zeige stattdessen den Pill-Stil")
        // Bewusst NUR im Speicher: Die gespeicherte Wahl des Nutzers bleibt
        // stehen. Ein einmaliger Fehlschlag (VM, schneller Benutzerwechsel)
        // darf seine Einstellung nicht dauerhaft überschreiben, ohne dass er
        // erfährt, warum sein Overlay anders aussieht.
        DispatchQueue.main.async { OverlayStyleFallback.orbUnavailable = true }
    }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.preferredFramesPerSecond = 60
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.framebufferOnly = true
        v.wantsLayer = true
        v.layer?.isOpaque = false
        if let device = v.device {
            if !context.coordinator.setup(device: device) {
                Self.fallBackToPill("Shader-Kompilierung fehlgeschlagen")
            }
        } else {
            Self.fallBackToPill("kein Metal-Gerät")
        }
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // Kein 60-fps-Rendering im Hintergrund, wenn das Overlay ausgeblendet ist
        view.isPaused = !state.overlayVisible
    }
}
