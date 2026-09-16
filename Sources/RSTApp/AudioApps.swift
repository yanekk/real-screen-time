import AppKit
import CoreAudio
import Darwin
import RSTCore

/// **Which apps are making sound right now** (DESIGN §2.2), so the evictor can quit them when
/// a cover is required. Covering a window hides its picture but not its sound; a Chrome tab
/// playing YouTube keeps playing behind the cover, and locking the screen does not help
/// because Chrome is still alive. Quitting the owning app is what actually stops the sound.
///
/// The route is CoreAudio's process API, settled by the T00 spike on this exact machine
/// (ad-hoc signed, Command Line Tools only): `kAudioHardwarePropertyProcessObjectList` plus
/// per-process `kAudioProcessPropertyIsRunningOutput` and `kAudioProcessPropertyPID`. Reading
/// these needs no entitlement and raised no permission prompt — only *tapping* audio is
/// privileged, and this taps nothing. If the API had failed here the fallback was a fixed
/// bundle-id list; T00 confirmed it works, so this is the real route.
///
/// **The emitting pid is often a helper, not the app.** Chrome plays audio from a renderer
/// process whose pid is not an application at all — `NSRunningApplication(pid:)` returns nil
/// for it. `terminate()` must target the *owning* app, so every emitting pid is walked up its
/// parent chain to the first ancestor that is a real application. A pid whose chain holds no
/// application (a system audio daemon such as `coreaudiod`) is dropped: there is nothing there
/// to quit, and it is not what §2.2 means by "an app making sound".
extension FullscreenEvictor {

    /// Every application currently outputting audio, mapped to the owning app and our own
    /// process excluded. Deduplicated by pid — a helper and its owner resolve to the one app.
    ///
    /// Returns an empty list, not a crash, if the CoreAudio API is unavailable: the fullscreen
    /// half of the eviction still runs, and a missing audio list is a degraded evictor, never a
    /// dropped cover.
    static func audioEmittingApps() -> [App] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [App] = []
        var seen = Set<pid_t>()

        for object in processAudioObjects() {
            guard isRunningOutput(object) == true, let emitting = pid(of: object) else { continue }
            // Map the emitting pid (often a renderer helper) to the app to quit. No owning
            // application in the parent chain means a system daemon, not a media app — skip.
            guard let owner = owningApplication(of: emitting) else { continue }
            let ownerPID = owner.processIdentifier
            // **Exclude ourselves.** The app plays its own spoken warnings and cover chime, so
            // its own pid can show up here; quitting it would drop the cover. §2.2.
            guard ownerPID != ownPID, seen.insert(ownerPID).inserted else { continue }
            found.append(App(pid: ownerPID,
                             name: owner.localizedName ?? owner.bundleIdentifier ?? "pid \(ownerPID)"))
        }
        return found
    }

    // MARK: - CoreAudio

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The per-process audio objects, or `[]` if the API is unavailable or reports none.
    private static func processAudioObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &dataSize, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Whether this process object is outputting audio *now*. T00 confirmed this drops to
    /// false on pause, so a paused tab is not quit — only one actually making sound is.
    private static func isRunningOutput(_ object: AudioObjectID) -> Bool? {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: - pid → owning application

    /// Walk the parent chain to the first ancestor that is a real application, or nil if none
    /// is. The emitting pid itself is tried first, so an app emitting directly is returned as
    /// itself; a renderer helper resolves up to its owner (Chrome's case, verified in T00).
    ///
    /// The eight-hop cap is a guard against a broken parent chain, not a real depth — a
    /// helper is one hop from its app — but a loop reading `sysctl` must never be unbounded.
    private static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 8 {
            if let app = NSRunningApplication(processIdentifier: p) { return app }
            current = parentPID(of: p)
            hops += 1
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
