import AVFoundation
import CoreAudio
import Foundation
import Network

/// Sender half of the fork's media link (see Shared/MediaLink.swift). Each
/// receiver has its own audio devices on this Mac, "<name> (OpenDisplay)",
/// from the drivers tools/build-audio-drivers.sh builds:
/// - sound played to its output device is forwarded to the receiver,
/// - the receiver's microphone arrives on its input device, and the
///   receiver is asked for its mic only while some app records from it.
final class MediaSender: NSObject {
    private let queue = DispatchQueue(label: "opendisplay.media.sender")
    private var conn: NWConnection?
    private var soundIn: AudioQueueRef?
    private var driver: String?
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

    /// `receiverName` picks the receiver's audio devices (e.g. "Kaleb's MacBook Air").
    func connect(host: NWEndpoint.Host, displayPort: UInt16, receiverName: String) {
        queue.async { [self] in
            disconnectOnQueue()
            generation += 1
            driver = AudioDevices.driver(for: receiverName)
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
        if let soundIn { AudioQueueDispose(soundIn, true) }
        soundIn = nil
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
        if let driver {
            // Reading the speaker mirror is audio input to macOS: without the
            // microphone grant it silently delivers zeros.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if !granted { Log.info("media: microphone access denied; sound forwarding is silent") }
                self.queue.async { if self.generation == gen { self.startSoundForwarding(driver) } }
            }
            startMicBridge(driver)
        } else {
            Log.info("media: no OpenDisplay audio devices for this receiver; sound and mic off")
        }
        // The MacBook camera runs while an app watches the virtual camera.
        // `defaults write <sender bundle id> cameraDebug -bool YES` forces it on
        // for testing without the extension.
        if VirtualCamera.shared.isInUse || UserDefaults.standard.bool(forKey: "cameraDebug") {
            send(.control, Data("{\"camera\":true}".utf8))
        }
    }

    // MARK: Sound: "<name> (OpenDisplay)" output -> receiver

    /// Reads the output device's hidden mirror. Planar Float32 stereo goes
    /// out as ODAU; while nothing plays, the driver delivers silence.
    private func startSoundForwarding(_ driver: String) {
        var format = AudioStreamBasicDescription(
            mSampleRate: MediaLink.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var input: AudioQueueRef?
        var status = AudioQueueNewInputWithDispatchQueue(&input, &format, 0, queue) { [weak self] aq, buffer, _, _, _ in
            let frames = Int(buffer.pointee.mAudioDataByteSize) / 8
            if frames > 0 {
                let interleaved = UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self),
                                                      count: frames * 2)
                var planar = [Float](repeating: 0, count: frames * 2)
                for frame in 0..<frames {
                    planar[frame] = interleaved[frame * 2]
                    planar[frames + frame] = interleaved[frame * 2 + 1]
                }
                self?.send(.sound, planar.withUnsafeBytes { Data($0) })
            }
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
        guard status == noErr, let input else { Log.info("media: sound input failed (\(status))"); return }
        var uid = "\(driver)Out_2_UID" as CFString
        status = AudioQueueSetProperty(input, kAudioQueueProperty_CurrentDevice, &uid,
                                       UInt32(MemoryLayout<CFString>.size))
        for _ in 0..<3 {   // 3 x 20 ms in flight
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(input, 960 * 8, &buffer)
            if let buffer { AudioQueueEnqueueBuffer(input, buffer, 0, nil) }
        }
        guard status == noErr, AudioQueueStart(input, nil) == noErr else {
            Log.info("media: cannot read \(driver)Out (\(status))")
            AudioQueueDispose(input, true)
            return
        }
        soundIn = input
        Log.info("media: forwarding \(driver)Out to the receiver")
    }

    // MARK: Mic: receiver mic -> "<name> (OpenDisplay)" input

    private func startMicBridge(_ driver: String) {
        guard let visibleMic = AudioDevices.device(uid: "\(driver)In_UID"),
              startMicOutput(uid: "\(driver)In_2_UID") else {
            Log.info("media: \(driver)In not installed; receiver mic unavailable")
            return
        }

        // Ask for the receiver's mic only while some app records from its
        // input device, so the receiver's mic light is not on all the time.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Release only after 3 quiet polls: device reconfiguration
            // briefly hides the recording app.
            if AudioDevices.otherProcessRecording(from: visibleMic) { self.micIdlePolls = 0 } else { self.micIdlePolls += 1 }
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

    /// An AudioQueue on the input device's hidden mirror. Unlike AVAudioEngine
    /// it survives the device being reconfigured when a recording app opens it.
    private func startMicOutput(uid deviceUID: String) -> Bool {
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
        var uid = deviceUID as CFString
        status = AudioQueueSetProperty(out, kAudioQueueProperty_CurrentDevice, &uid,
                                       UInt32(MemoryLayout<CFString>.size))
        guard status == noErr else {
            Log.info("media: cannot route mic to \(deviceUID) (\(status))")
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
    /// Receivers with drivers, matched against the receiver's name.
    /// ponytail: names fixed at driver build time; add one per new receiver.
    static let receiverNames = ["MacBook Air", "iPad"]

    /// Driver prefix ("ODMacBookAir") for a receiver, if its devices are installed.
    static func driver(for receiverName: String) -> String? {
        guard let name = receiverNames.first(where: { receiverName.localizedCaseInsensitiveContains($0) })
        else { return nil }
        let driver = "OD" + name.replacingOccurrences(of: " ", with: "")
        return device(uid: "\(driver)Out_UID") != nil ? driver : nil
    }

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
