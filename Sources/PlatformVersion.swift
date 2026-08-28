import Foundation

enum PlatformVersion {
    static var isMacOS27OrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
}
