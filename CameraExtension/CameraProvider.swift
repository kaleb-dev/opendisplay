import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

/// Virtual camera fed by the OpenDisplay sender: the app pushes decoded
/// MacBook camera frames into the sink stream, and every frame is passed
/// straight on to the source stream that FaceTime and other apps read.
/// Based on Xcode's Camera Extension template, plus a sink stream.
private let inUseProperty = CMIOExtensionProperty(rawValue: "4cc_\(VirtualCameraIDs.inUseSelector)_glob_0000")

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStreamSource!
    private var sink: CameraStreamSource!
    private var sinkClient: CMIOExtensionClient?
    private var sourceClients = 0
    private let format: CMFormatDescription

    init(localizedName: String) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: VirtualCameraIDs.width, height: VirtualCameraIDs.height,
                                       extensions: nil, formatDescriptionOut: &description)
        format = description!
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: VirtualCameraIDs.device,
                                     legacyDeviceID: VirtualCameraIDs.device.uuidString, source: self)
        let frame = CMTime(value: 1, timescale: VirtualCameraIDs.framesPerSecond)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: frame,
                                                     minFrameDuration: frame, validFrameDurations: nil)
        source = CameraStreamSource(localizedName: "MacBook Camera", streamID: VirtualCameraIDs.sourceStream,
                                    direction: .source, format: streamFormat, owner: self)
        sink = CameraStreamSource(localizedName: "MacBook Camera Sink", streamID: VirtualCameraIDs.sinkStream,
                                  direction: .sink, format: streamFormat, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, inUseProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "OpenDisplay MacBook Camera" }
        if properties.contains(inUseProperty) {
            result.setPropertyState(CMIOExtensionPropertyState(value: (sourceClients > 0 ? "1" : "0") as NSString),
                                    forProperty: inUseProperty)
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Stream callbacks

    func started(_ stream: CameraStreamSource, client: CMIOExtensionClient?) {
        if stream === source {
            sourceClients += 1
            announceInUse()
        } else {
            sinkClient = client
            consumeNext()
        }
    }

    func stopped(_ stream: CameraStreamSource) {
        if stream === source {
            sourceClients = max(0, sourceClients - 1)
            announceInUse()
        } else {
            sinkClient = nil
        }
    }

    /// Clients cache device properties; push the new value or the sender
    /// keeps reading the old one.
    private func announceInUse() {
        let state = CMIOExtensionPropertyState<AnyObject>(value: (sourceClients > 0 ? "1" : "0") as NSString)
        device.notifyPropertiesChanged([inUseProperty: state])
    }

    /// Pull one frame from the app, pass it to the source stream, repeat.
    private func consumeNext() {
        guard let client = sinkClient else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
            guard let self else { return }
            if let buffer {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if self.sourceClients > 0 {
                    self.source.stream.send(buffer, discontinuity: [],
                                            hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                          hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                self.sink.stream.notifyScheduledOutputChanged(output)
            }
            self.consumeNext()
        }
    }
}

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private weak var owner: CameraDeviceSource?
    private var pendingClient: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction,
         format: CMIOExtensionStreamFormat, owner: CameraDeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: VirtualCameraIDs.framesPerSecond)
        }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        pendingClient = client
        return true
    }

    func startStream() throws {
        owner?.started(self, client: pendingClient)
    }

    func stopStream() throws {
        owner?.stopped(self)
    }
}

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: VirtualCameraIDs.name)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "OpenDisplay" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
