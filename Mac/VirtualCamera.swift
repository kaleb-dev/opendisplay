import CoreMediaIO
import Foundation
import SystemExtensions

/// Sender half of the virtual camera: installs the camera extension, feeds
/// it decoded MacBook frames through its sink stream, and reports whether an
/// app (FaceTime) is watching, so the MacBook camera only runs when needed.
final class VirtualCamera: NSObject, OSSystemExtensionRequestDelegate {
    /// One per app: the sender runs a MacSender (and MediaSender) per device.
    static let shared = VirtualCamera()
    /// Posted with `object` = Bool in-use whenever the camera gains or loses its last viewer.
    static let inUseChanged = Notification.Name("VirtualCameraInUseChanged")

    private let queue = DispatchQueue(label: "opendisplay.virtualcamera")
    private var device: CMIOObjectID = 0
    private var sinkStream: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    private var poll: DispatchSourceTimer?
    private var inUse = false

    private(set) var isInUse = false
    private var started = false

    private var extensionID: String { (Bundle.main.bundleIdentifier ?? "") + ".camera" }

    /// Install or update the extension (needs the app in /Applications and,
    /// the first time, the user's approval in System Settings), then watch it.
    func start() {
        guard !started else { return }
        started = true
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        poll = timer
    }

    /// Hand one decoded frame (BGRA, CameraFormat size) to the extension.
    func push(_ image: CVPixelBuffer) {
        queue.async { [self] in
            guard let sinkQueue, CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue)
            else { return }
            var format: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard let format, CMSampleBufferCreateForImageBuffer(
                allocator: nil, imageBuffer: image, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                let sample else { return }
            CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sample).toOpaque())
        }
    }

    private func tick() {
        if device == 0 { connectSink() }
        guard device != 0 else { return }
        let watched = readInUse()
        if watched != inUse {
            inUse = watched
            Log.info("virtual camera \(watched ? "in use" : "idle")")
            isInUse = watched
            NotificationCenter.default.post(name: Self.inUseChanged, object: watched)
        }
    }

    // MARK: CoreMediaIO plumbing

    private func connectSink() {
        guard let found = Self.objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first(where: { Self.uid($0) == VirtualCameraIDs.device.uuidString }) else { return }
        // The sink is the stream the app writes into; the extension adds it second.
        let streams = Self.objects(found, kCMIODevicePropertyStreams)
        guard streams.count >= 2 else { return }
        let sink = streams[1]
        var queueOut: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueOut) == noErr,
              let queueOut else { return }
        sinkQueue = queueOut.takeRetainedValue()
        guard CMIODeviceStartStream(found, sink) == noErr else { sinkQueue = nil; return }
        device = found
        sinkStream = sink
        Log.info("virtual camera connected")
    }

    private func readInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: Self.fourCC(VirtualCameraIDs.inUseSelector),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil,
                                               UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        guard status == noErr, let value else {
            // The extension went away (update, reboot): reconnect next tick.
            device = 0
            sinkQueue = nil
            return false
        }
        return (value.takeRetainedValue() as String) == "1"
    }

    private static func fourCC(_ text: String) -> CMIOObjectPropertySelector {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func uid(_ object: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                        &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Log.info("virtual camera: approve it in System Settings > General > Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Log.info("virtual camera extension installed (\(result.rawValue))")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Log.info("virtual camera extension failed: \(error.localizedDescription)")
    }
}
