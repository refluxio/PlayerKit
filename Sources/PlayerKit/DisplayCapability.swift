import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Snapshot of the output display's HDR capabilities at a given moment.
///
/// `NativeBackend` uses this together with `VideoStreamAttributes` to pick the
/// right `RendererStrategy`. macOS EDR-capable displays report `supportsEDR=true`
/// and a target peak luminance (typically 1000 nits); non-EDR panels, iOS and
/// tvOS fall back to the SDR 203-nit diffuse-white path.
///
/// This is a pure value type — no AppKit/UIKit dependency — so PlayerKit can
/// stay cross-platform. The caller (reflex apple `PlayerController`) probes
/// `NSScreen.maximumExtendedDynamicRangeColorComponentValue` and constructs the
/// appropriate `DisplayCapability`. See `PlayerController.swift`.
public struct DisplayCapability: Sendable, Equatable {

    /// Whether the display can enter EDR mode (>1.0 component values in
    /// extended-linear Display P3). On macOS this corresponds to an XDR panel
    /// or external HDR monitor; on iOS/tvOS it is probed from
    /// `UIScreen.maximumExtendedDynamicRangeColorComponentValue` (iPhone 12+
    /// HDR panels, iPad Pro XDR, HDR TVs on Apple TV).
    public var supportsEDR: Bool

    /// Peak luminance the renderer should tone-map toward, in cd/m².
    /// Used by `ToneMappingAlgorithm` to set `targetNits` in the shader uniform.
    public var targetPeakNits: Float

    /// Whether the display accepts 10-bit pixel buffers. True on all Apple
    /// platforms — used to gate `RendererStrategy.pixelFormat10Bit`.
    public var supports10Bit: Bool

    /// Whether HLG OOTF should be applied on this display. EDR displays need
    /// a system-gamma OOTF for HLG content; non-EDR displays already get SDR
    /// tone-compressed output and skip the OOTF.
    public var supportsHLGOOTF: Bool

    /// Construct a capability snapshot.
    public init(supportsEDR: Bool,
                targetPeakNits: Float,
                supports10Bit: Bool,
                supportsHLGOOTF: Bool) {
        self.supportsEDR = supportsEDR
        self.targetPeakNits = targetPeakNits
        self.supports10Bit = supports10Bit
        self.supportsHLGOOTF = supportsHLGOOTF
    }

    /// macOS XDR / external HDR monitor. 1000-nit target, 10-bit, OOTF enabled.
    public static let macEDR = DisplayCapability(
        supportsEDR: true, targetPeakNits: 1000,
        supports10Bit: true, supportsHLGOOTF: true)

    /// macOS SDR panel. Renderer uses CIToneCurve fake-PQ path.
    public static let macSDR = DisplayCapability(
        supportsEDR: false, targetPeakNits: 203,
        supports10Bit: true, supportsHLGOOTF: false)

    /// iPhone / iPad / Apple TV SDR panel (no EDR headroom). HDR content on
    /// this display is shown via the tone-mapped SDR path.
    public static let appleMobile = DisplayCapability(
        supportsEDR: false, targetPeakNits: 203,
        supports10Bit: true, supportsHLGOOTF: false)

    /// iPhone / iPad / Apple TV panel currently in EDR mode — probed the same
    /// way as `.macEDR`: `UIScreen.maximumExtendedDynamicRangeColorComponentValue`
    /// reports the current max headroom in SDR-white multiples (iPhone 12 and
    /// later report ~4-8 while playing HDR; SDR panels stay at 1.0). Peak target
    /// mirrors `.macEDR` (1000 nits): iPhone HDR panels peak at ~800-1200 nits
    /// and HDR TVs 600-1000+, so 1000 is a safe common tone-map target.
    public static let mobileEDR = DisplayCapability(
        supportsEDR: true, targetPeakNits: 1000,
        supports10Bit: true, supportsHLGOOTF: true)
}

extension DisplayCapability {

    /// Probe the current main screen's EDR capability. On macOS reads
    /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue`; on iOS/tvOS
    /// reads the same-named `UIScreen` property. Other platforms return
    /// `.appleMobile`.
    ///
    /// The property is > 1.0 iff the panel is currently in EDR mode (XDR /
    /// external HDR monitor with HDR enabled in System Settings on macOS;
    /// HDR-capable mobile panel or HDR TV on iOS/tvOS). The probe returns
    /// `.macEDR` / `.mobileEDR` when the value is > 1.0, the SDR variant
    /// otherwise.
    ///
    /// - Note: Main-thread-only (NSScreen/UIScreen must be accessed from main).
    @MainActor
    public static func probeCurrent() -> DisplayCapability {
#if os(macOS)
        guard let screen = NSScreen.main else { return .macSDR }
        let peak = screen.maximumExtendedDynamicRangeColorComponentValue
        return peak > 1.0 ? .macEDR : .macSDR
#elseif os(iOS) || os(tvOS)
        // UIScreen.main is soft-deprecated since iOS 16 (scene-based APIs are
        // preferred), but PlayerKit is a framework without scene context, and
        // this remains the only context-free entry point. `potentialEDRHeadroom`
        // is the panel's max headroom in SDR-white multiples when EDR is
        // enabled, regardless of whether EDR is currently active (iPhone 12+
        // HDR panels report ~4-8, HDR TVs ~2-6, SDR panels 1.0) — available on
        // iOS 16+ / tvOS 16+, so no availability gate given the iOS 17/tvOS 17
        // package floor.
        let peak = UIScreen.main.potentialEDRHeadroom
        return peak > 1.0 ? .mobileEDR : .appleMobile
#else
        return .appleMobile
#endif
    }

#if os(macOS)
    /// The `NotificationCenter` payload posted by macOS when the display
    /// configuration changes (display connected/disconnected, EDR toggled,
    /// resolution change). PlayerController subscribes to this to refresh
    /// `NativeBackend.displayCapability`.
    public static let displayConfigurationDidChangeNotification: Notification.Name =
        NSApplication.didChangeScreenParametersNotification
#endif
}
