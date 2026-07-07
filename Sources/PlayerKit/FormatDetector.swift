import Foundation

public enum FormatDetector {
    public static func isHardwareDecodable(codecId: String) -> Bool {
        switch codecId {
        case "h264", "avc", "avc1":
            return true
        case "hevc", "h265", "hev1", "hvc1":
            return true
        case "av1":
            return true
        default:
            return false
        }
    }
}
