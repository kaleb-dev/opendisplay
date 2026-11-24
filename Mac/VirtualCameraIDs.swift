import Foundation

/// Shared by the sender app and its camera extension. One camera per
/// receiver, named like its audio devices. IDs are fixed forever: apps
/// remember a camera by its device ID.
enum VirtualCameraIDs {
    /// Same list as AudioDevices.receiverNames; index = camera slot.
    static let receivers = ["MacBook Air", "iPad"]
    static func name(_ slot: Int) -> String { "\(receivers[slot]) (OpenDisplay)" }
    static func device(_ slot: Int) -> UUID { id(slot, 0) }
    static func sourceStream(_ slot: Int) -> UUID { id(slot, 1) }
    static func sinkStream(_ slot: Int) -> UUID { id(slot, 2) }
    /// Slot of the receiver whose name contains one of `receivers`.
    static func slot(for receiverName: String) -> Int? {
        receivers.firstIndex { receiverName.localizedCaseInsensitiveContains($0) }
    }
    /// Custom device property: "1" while some app is watching the camera.
    static let inUseSelector = "odus"
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let framesPerSecond: Int32 = 30

    private static func id(_ slot: Int, _ kind: Int) -> UUID {
        UUID(uuidString: String(format: "6F1C3D2A-8B4E-4C7A-9E21-0D5B7A3F9C%d%d", slot + 1, kind))!
    }
}
