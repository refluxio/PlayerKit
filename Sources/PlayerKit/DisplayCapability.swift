import Foundation
#if os(macOS)
import AppKit
#endif

/// Snapshot of the output display's HDR capabilities at a given moment.
///
/// `NativeBackend` uses this together with `VideoStreamAttributes` to pick the
/// right `RendererStrategy`. macOS EDR-capable displays report `supportsEDR=true`
/// and a target peak luminance (typically 1000 nits); non-EDR panels, iOS and
/// tvOS fall back to the SDR 203-nit diffuse-white path.
///
/// This is a pure value type — no AppKit/UIKit dependency — so PlayerKit can
/// stay cross-platform. The caller (reflux apple `PlayerController`) probes
/// `NSScreen.maximumExtendedDynamicRangeColorComponentValue` and constructs the
/// appropriate `DisplayCapability`. See `PlayerController.swift`.
public struct DisplayCapability: Sendable, Equatable {

    /// Whether the display can enter EDR mode (>1.0 component values in
    /// extended-linear Display P3). On macOS this corresponds to an XDR panel
    /// or external HDR monitor; iOS/tvOS currently report false.
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

    /// iPhone / iPad / Apple TV. EDR is not available; HDR content is shown via
    /// CoreImage's automatic EDR fallback path (8-bit + CIToneCurve).
    public static let appleMobile = DisplayCapability(
        supportsEDR: false, targetPeakNits: 203,
        supports10Bit: true, supportsHLGOOTF: false)
}

extension DisplayCapability {

    /// Probe the current main screen's EDR capability. On macOS reads
    /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue`; on iOS/tvOS
    /// returns `.appleMobile` (EDR is not available).
    ///
    /// `maximumExtendedDynamicRangeColorComponentValue` is > 1.0 iff the panel
    /// is currently in EDR mode (XDR or external HDR monitor with HDR enabled
    /// in System Settings). The probe returns `macEDR` when the value is > 1.0,
    /// `macSDR` otherwise.
    ///
    /// - Note: Main-thread-only on macOS (NSScreen must be accessed from main).
    @MainActor
    public static func probeCurrent() -> DisplayCapability {
#if os(macOS)
        guard let screen = NSScreen.main else { return .macSDR }
        let peak = screen.maximumExtendedDynamicRangeColorComponentValue
        return peak > 1.0 ? .macEDR : .macSDR
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
