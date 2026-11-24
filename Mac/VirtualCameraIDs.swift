import Foundation

/// Shared by the sender app and its camera extension. Fixed forever: apps
/// remember a camera by its device ID.
enum VirtualCameraIDs {
    static let name = "MacBook Camera (OpenDisplay)"
    static let device = UUID(uuidString: "6F1C3D2A-8B4E-4C7A-9E21-0D5B7A3F9C10")!
    static let sourceStream = UUID(uuidString: "6F1C3D2A-8B4E-4C7A-9E21-0D5B7A3F9C11")!
    static let sinkStream = UUID(uuidString: "6F1C3D2A-8B4E-4C7A-9E21-0D5B7A3F9C12")!
    /// Custom device property: "1" while some app is watching the camera.
    static let inUseSelector = "odus"
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let framesPerSecond: Int32 = 30
}
