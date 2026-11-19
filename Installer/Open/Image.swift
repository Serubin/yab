import AppKit

// The disk image this launcher came in, put away once yab is open, so its
// Finder window closes behind the browser's first one and nothing is left on
// the desktop. Only this image: read-only, carrying this launcher's own build
// stamp, and still the same volume when the time comes. Never forced, and
// Finder is never scripted; a busy image stays where it is.

struct Image {
    let device: String
    let uuid: String

    /// The image, if this launcher is running from one. Gatekeeper may run a
    /// downloaded launcher from a translocated copy; then only one mounted
    /// image with this exact stamp can be where it came from.
    static func containingLauncher() -> Image? {
        guard let stamp = Bundle.main.object(forInfoDictionaryKey: "YabImageStamp") as? String,
              let info = plist("/usr/bin/hdiutil", ["info", "-plist"]),
              let images = info["images"] as? [[String: Any]] else { return nil }
        var found: [(mount: String, image: Image)] = []
        for image in images where image["writeable"] as? Bool == false {
            let mounted = (image["system-entities"] as? [[String: Any]] ?? []).filter { $0["mount-point"] is String }
            guard mounted.count == 1,
                  let mount = mounted[0]["mount-point"] as? String,
                  let device = mounted[0]["dev-entry"] as? String else { continue }
            let root = URL(fileURLWithPath: mount).resolvingSymlinksInPath()
            let launcher = root.appendingPathComponent("Open pane.app/Contents/Info.plist")
            guard NSDictionary(contentsOf: launcher)?["YabImageStamp"] as? String == stamp,
                  let uuid = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            else { continue }
            found.append((root.path, Image(device: device, uuid: uuid)))
        }
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if let own = found.first(where: { here.hasPrefix($0.mount + "/") }) { return own.image }
        guard Bundle.main.bundleURL.pathComponents.contains("AppTranslocation"), found.count == 1 else { return nil }
        return found[0].image
    }

    /// A shell outlives this process, waits for it to be gone, while it
    /// runs, its own executable keeps the volume busy, and then asks for
    /// the image to be detached, checking first that the device is still
    /// the volume it was.
    func ejectAfterExit() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.currentDirectoryURL = URL(fileURLWithPath: "/")
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        // Values go in as arguments, never as shell source.
        shell.arguments = ["-c", Self.script, "yab-eject", String(getpid()), device, uuid]
        try? shell.run()
    }

    private static let script = #"""
    n=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -lt 100 ] || exit 0
        /bin/sleep 0.1
    done
    /bin/sleep 0.25
    for attempt in 1 2 3; do
        uuid=$(/usr/sbin/diskutil info -plist "$2" 2>/dev/null | /usr/bin/plutil -extract VolumeUUID raw -o - - 2>/dev/null)
        [ "$uuid" = "$3" ] || exit 0
        /usr/bin/hdiutil detach "$2" >/dev/null 2>&1 && exit 0
        /bin/sleep 0.5
    done
    """#

    private static func plist(_ executable: String, _ arguments: [String]) -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
