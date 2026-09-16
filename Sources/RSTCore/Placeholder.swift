import Foundation

/// Placeholder so `RSTCore` is a real target before T02 starts filling it in.
///
/// Everything in this target is Foundation + CryptoKit only: no AppKit, no SwiftUI, no
/// system calls, and no system-time reads — time arrives as a parameter. `BoundaryTests`
/// enforces the import half of that rule automatically; the rest is in CLAUDE.md.
public enum RSTCore {
    public static let name = "RealScreenTime"
}
