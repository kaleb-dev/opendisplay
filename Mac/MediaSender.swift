import AVFoundation
import CoreAudio
import Foundation
import Network
import ScreenCaptureKit

/// Sender half of the fork's media link (see Shared/MediaLink.swift):
/// streams this Mac's system sound to the receiver, plays the receiver's
/// microphone into BlackHole 2ch so FaceTime and friends can pick it as a mic,
/// and asks for the mic only while another app is actually recording from
/// BlackHole.
final class MediaSender: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "opendisplay.media.sender")
    private var conn: NWConnection?
    private var stream: SCStream?
    private var micOut: AudioQueueRef?
    private var micFifo: [Float] = []
    private var micPoll: DispatchSourceTimer?
    private var micWanted = false
    private var micIdlePolls = 3
    private var generation = 0

    private var cameraFrames = 0
    private lazy var cameraDecoder = CameraDecoder { [weak self] image in
        guard let self else { return }
        self.cameraFrames += 1
        // ponytail: proof of life until the virtual camera consumes these.
        if self.cameraFrames % 150 == 1 {
            Log.info("camera: decoded frame \(self.cameraFrames) "
                + "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))")
        }
        VirtualCamera.shared.push(image)
    }
    private var cameraObserver: NSObjectProtocol?

    override init() {
        super.init()
        cameraObserver = NotificationCenter.default.addObserver(
            forName: VirtualCamera.inUseChanged, object: nil, queue: nil) { [weak self] note in
            guard let inUse = note.object as? Bool else { return }
            self?.queue.async { self?.send(.control, Data("{\"camera\":\(inUse)}".utf8)) }
        }
        VirtualCamera.shared.start()
    }

    func connect(host: NWEndpoint.Host, displayPort: UInt16) {
        queue.async { [self] in
            disconnectOnQueue()
            generation += 1
            let gen = generation
            let port = NWEndpoint.Port(rawValue: displayPort &+ MediaLink.portOffset)!
            let params = NWParameters.tcp
            params.serviceClass = .interactiveVoice
            let conn = NWConnection(host: host, port: port, using: params)
            self.conn = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Log.info("media link ready to \(host):\(port)")
                    self.queue.async { self.startOnQueue(gen) }
                case .failed(let error):
                    // A stock receiver has no media listener: stay silent.
                    Log.info("media link unavailable (\(error)); sound/mic/camera off")
                    self.queue.async { if self.generation == gen { self.disconnectOnQueue() } }
                default: break
                }
            }
            MediaLink.receive(on: conn, onFrame: { [weak self] tag, data in
                guard let self, self.generation == gen else { return }
                switch tag {
                case .mic: self.playMic(data)
                case .camera: self.cameraDecoder.decode(data)
                default: break
                }
            }, onEnd: { [weak self] in
                self?.queue.async { if self?.generation == gen { self?.disconnectOnQueue() } }
            })
            conn.start(queue: queue)
        }
    }

    func disconnect() {
        queue.async { [self] in generation += 1; disconnectOnQueue() }
    }

    private func disconnectOnQueue() {
        conn?.cancel()
        conn = nil
        stream?.stopCapture { _ in }
        stream = nil
        micPoll?.cancel()
        micPoll = nil
        if let micOut { AudioQueueDispose(micOut, true) }
        micOut = nil
        micFifo = []
        micWanted = false
        micIdlePolls = 3
    }

    private func send(_ tag: MediaTag, _ payload: Data) {
        conn?.send(content: MediaLink.frame(tag, payload), completion: .contentProcessed { _ in })
    }

    private func startOnQueue(_ gen: Int) {
        guard generation == gen else { return }
        startMicBridge()
        // The MacBook camera runs while an app watches the virtual camera.
        // `defaults write <sender bundle id> cameraDebug -bool YES` forces it on
        // for testing without the extension.
        if VirtualCamera.shared.isInUse || UserDefaults.standard.bool(forKey: "cameraDebug") {
            send(.control, Data("{\"camera\":true}".utf8))
        }
        Task { await self.startSoundCapture(gen) }
    }

    // MARK: Sound: system audio -> receiver

    private func startSoundCapture(_ gen: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true   // never loop the mic back out
            config.sampleRate = Int(MediaLink.sampleRate)
            config.channelCount = 2
            // Audio only: the smallest, slowest video SCK allows.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            queue.async { [self] in
                if generation == gen { self.stream = stream } else { stream.stopCapture { _ in } }
            }
            Log.info("media: system sound capture started")
        } catch {
            Log.info("media: system sound capture failed: \(error)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, stream === self.stream, CMSampleBufferIsValid(sampleBuffer) else { return }
        // SCK delivers Float32 planar; send the planes back to back (2 channels).
        var payload = Data()
        try? sampleBuffer.withAudioBufferList { list, _ in
            let planes = Array(list)
            guard let first = planes.first, let firstData = first.mData else { return }
            let left = Data(bytes: firstData, count: Int(first.mDataByteSize))
            payload.append(left)
            if planes.count > 1, let right = planes[1].mData {
                payload.append(Data(bytes: right, count: Int(planes[1].mDataByteSize)))
            } else {
                payload.append(left)   // mono source: duplicate
            }
        }
        if !payload.isEmpty { send(.sound, payload) }
    }

    // MARK: Mic: receiver mic -> BlackHole 2ch

    private func startMicBridge() {
        guard let blackHole = AudioDevices.device(uid: "BlackHole2ch_UID") else {
            Log.info("media: BlackHole 2ch not installed; MacBook mic unavailable")
            return
        }
        guard startMicOutput() else { return }

        // Ask for the MacBook mic only while some other app records from
        // BlackHole, so its orange mic light is not on all the time.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Release only after 3 quiet polls: device reconfiguration
            // briefly hides the recording app.
            if AudioDevices.otherProcessRecording(from: blackHole) { self.micIdlePolls = 0 } else { self.micIdlePolls += 1 }
            let wanted = self.micIdlePolls < 3
            if wanted != self.micWanted {
                self.micWanted = wanted
                Log.info("media: \(wanted ? "requesting" : "releasing") receiver mic")
                self.send(.control, Data("{\"mic\":\(wanted)}".utf8))
            }
        }
        timer.resume()
        micPoll = timer
    }

    /// An AudioQueue on BlackHole. Unlike AVAudioEngine it survives
    /// BlackHole being reconfigured when a recording app opens it.
    private func startMicOutput() -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: MediaLink.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var out: AudioQueueRef?
        // The callback runs on `queue`, the same queue playMic fills the FIFO on.
        var status = AudioQueueNewOutputWithDispatchQueue(&out, &format, 0, queue) { [weak self] aq, buffer in
            let frames = Int(buffer.pointee.mAudioDataBytesCapacity) / 4
            let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            let available = min(frames, self?.micFifo.count ?? 0)
            if available > 0 {
                self?.micFifo.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: available) }
                self?.micFifo.removeFirst(available)
            }
            (samples + available).initialize(repeating: 0, count: frames - available)   // underrun: silence
            buffer.pointee.mAudioDataByteSize = UInt32(frames * 4)
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
        guard status == noErr, let out else { Log.info("media: mic output failed (\(status))"); return false }
        var uid = "BlackHole2ch_UID" as CFString
        status = AudioQueueSetProperty(out, kAudioQueueProperty_CurrentDevice, &uid,
                                       UInt32(MemoryLayout<CFString>.size))
        guard status == noErr else {
            Log.info("media: cannot route to BlackHole (\(status))")
            AudioQueueDispose(out, true)
            return false
        }
        for _ in 0..<3 {   // 3 x 20 ms in flight
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(out, 960 * 4, &buffer)
            guard let buffer else { continue }
            buffer.pointee.mAudioDataByteSize = 960 * 4
            memset(buffer.pointee.mAudioData, 0, 960 * 4)
            AudioQueueEnqueueBuffer(out, buffer, 0, nil)
        }
        status = AudioQueueStart(out, nil)
        guard status == noErr else { Log.info("media: mic output start failed (\(status))"); AudioQueueDispose(out, true); return false }
        micOut = out
        return true
    }

    private func playMic(_ data: Data) {
        guard micOut != nil else { return }
        data.withUnsafeBytes { micFifo.append(contentsOf: $0.bindMemory(to: Float.self)) }
        // ponytail: trim the oldest audio past 200 ms so latency cannot creep.
        let cap = Int(MediaLink.sampleRate * 0.2)
        if micFifo.count > cap { micFifo.removeFirst(micFifo.count - cap) }
    }
}

/// The few CoreAudio lookups the mic bridge needs.
enum AudioDevices {
    static func device(uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    /// True when a process other than this one is recording from `device`.
    static func otherProcessRecording(from device: AudioDeviceID) -> Bool {
        let me = getpid()
        return array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                     kAudioObjectPropertyScopeGlobal).contains { process in
            scalar(process, kAudioProcessPropertyPID, as: pid_t.self) != me
                && scalar(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1
                && array(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).contains(device)
        }
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
