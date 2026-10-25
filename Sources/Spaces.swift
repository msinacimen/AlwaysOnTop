import CoreGraphics
import Foundation

/// Which desktop (Space) a window is on, through the window server's private
/// CGS calls. They are looked up at runtime: if macOS drops one, every window
/// counts as being on the visible desktop and pins behave as if Spaces did
/// not exist.
enum Spaces {
    private typealias MainConnectionFunction = @convention(c) () -> UInt32
    private typealias CopySpacesForWindowsFunction = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFunction = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: type)
    }

    private static let connection: UInt32 = function("CGSMainConnectionID", as: MainConnectionFunction.self)?() ?? 0
    private static let copySpacesForWindows = function("CGSCopySpacesForWindows", as: CopySpacesForWindowsFunction.self)
    private static let copyManagedDisplaySpaces = function("CGSCopyManagedDisplaySpaces",
                                                           as: CopyManagedDisplaySpacesFunction.self)

    /// The Space each display is showing right now.
    private static func visibleSpaces() -> Set<UInt64>? {
        guard connection != 0, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return Set(displays.compactMap {
            (($0["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        })
    }

    /// Every Space the window belongs to, full-screen ones included.
    private static func spaces(of windowID: CGWindowID) -> [UInt64] {
        guard connection != 0, let copySpacesForWindows,
              let spaces = copySpacesForWindows(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return spaces.map(\.uint64Value)
    }

    /// True when the window sits on a desktop that no display is showing.
    /// Anything the window server cannot answer counts as false.
    static func isOnHiddenSpace(_ windowID: CGWindowID) -> Bool {
        guard let visible = visibleSpaces() else { return false }
        let own = spaces(of: windowID)
        return !own.isEmpty && visible.isDisjoint(with: own)
    }
}
