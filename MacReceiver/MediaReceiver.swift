import AVFoundation
import Foundation
import Network

/// Receiver half of the fork's media link (see Shared/MediaLink.swift):
/// plays the sender's system sound and, when the sender asks, records this
/// Mac's microphone and sends it back. Playback and mic share one engine
/// with voice processing, so the speaker output is the echo canceller's
/// reference and the caller does not hear themselves.
final class MediaReceiver {
    private let queue = DispatchQueue(label: "opendisplay.media.receiver")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var micConverter: AVAudioConverter?
    private var micOn = false
    private var queuedFrames = 0
    private var engineGeneration = 0
    private let soundFormat = AVAudioFormat(standardFormatWithSampleRate: MediaLink.sampleRate, channels: 2)!
    private let micFormat = AVAudioFormat(standardFormatWithSampleRate: MediaLink.sampleRate, channels: 1)!

    /// Camera hooks, set by the camera source: start/stop on request.
    var onCameraRequest: ((Bool) -> Void)?

    func start(displayPort: UInt16) {
        queue.async { [self] in
            guard listener == nil,
                  let port = NWEndpoint.Port(rawValue: displayPort &+ MediaLink.portOffset),
                  let listener = try? NWListener(using: .tcp, on: port) else {
                Log.info("media listener could not start")
                return
            }
            listener.newConnectionHandler = { [weak self] conn in self?.adopt(conn) }
            listener.start(queue: queue)
            self.listener = listener
            Log.info("media listener on tcp :\(port)")
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            dropConnection()
        }
    }

    /// Send a camera frame to the sender (called from the camera source).
    func sendCamera(_ data: Data) {
        queue.async { [self] in send(.camera, data) }
    }

    private func adopt(_ newConn: NWConnection) {
        dropConnection()   // one sender at a time; the newest wins
        conn = newConn
        Log.info("media link connected")
        MediaLink.receive(on: newConn, onFrame: { [weak self] tag, data in
            guard let self, self.conn === newConn else { return }
            switch tag {
            case .sound: self.play(data)
            case .control: self.handleControl(data)
            default: break
            }
        }, onEnd: { [weak self] in
            self?.queue.async { if self?.conn === newConn { self?.dropConnection() } }
        })
        newConn.start(queue: queue)
        rebuildEngine()
    }

    private func dropConnection() {
        guard conn != nil else { return }
        conn?.cancel()
        conn = nil
        micOn = false
        onCameraRequest?(false)
        engine?.stop()
        engine = nil
        player = nil
        Log.info("media link closed")
    }

    private func send(_ tag: MediaTag, _ payload: Data) {
        conn?.send(content: MediaLink.frame(tag, payload), completion: .contentProcessed { _ in })
    }

    private func handleControl(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let mic = message["mic"] as? Bool, mic != micOn {
            if mic {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    self.queue.async {
                        guard granted, self.conn != nil else {
                            Log.info("media: microphone access denied")
                            return
                        }
                        self.micOn = true
                        self.rebuildEngine()
                    }
                }
            } else {
                micOn = false
                rebuildEngine()
            }
        }
        if let camera = message["camera"] as? Bool {
            onCameraRequest?(camera)
        }
    }

    /// Voice processing can only be switched with the engine stopped, so a
    /// mic change rebuilds the whole engine. Without the mic, the input node
    /// is never touched and no recording indicator shows.
    private func rebuildEngine() {
        engine?.stop()
        engineGeneration += 1
        queuedFrames = 0
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            if micOn {
                // Voice processing fails to initialize (-10875) unless the
                // output side exists first; measured on macOS 27.2.
                _ = engine.mainMixerNode
                _ = engine.outputNode
                let input = engine.inputNode
                try input.setVoiceProcessingEnabled(true)
                let inputFormat = input.outputFormat(forBus: 0)
                micConverter = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1)
                    .flatMap { AVAudioConverter(from: $0, to: micFormat) }
                input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
                    self?.queue.async { self?.sendMic(buffer) }
                }
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: soundFormat)
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            Log.info("media: audio engine running (mic \(micOn ? "on" : "off"))")
        } catch {
            Log.info("media: audio engine failed: \(error)")
            self.engine = nil
            self.player = nil
        }
    }

    private func play(_ data: Data) {
        guard let player else { return }
        let frames = data.count / 8   // 2 planes of Float32
        // ponytail: drop rather than queue past 150 ms, latency must not creep.
        guard frames > 0, queuedFrames < Int(MediaLink.sampleRate * 0.15),
              let buffer = AVAudioPCMBuffer(pcmFormat: soundFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            memcpy(buffer.floatChannelData![0], base, frames * 4)
            memcpy(buffer.floatChannelData![1], base + frames * 4, frames * 4)
        }
        queuedFrames += frames
        let gen = engineGeneration
        player.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async { if self?.engineGeneration == gen { self?.queuedFrames -= frames } }
        }
    }

    private func sendMic(_ buffer: AVAudioPCMBuffer) {
        guard micOn, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        // Voice processing hands over several channels; channel 0 is the
        // cleaned-up voice. Downmixing them all gives silence.
        let frames = Int(buffer.frameLength)
        if buffer.format.sampleRate == MediaLink.sampleRate {
            send(.mic, Data(bytes: samples, count: frames * 4))
            return
        }
        guard let converter = micConverter,
              let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: buffer.frameLength),
              let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(
                  Double(frames) * MediaLink.sampleRate / buffer.format.sampleRate) + 32)
        else { return }
        mono.frameLength = buffer.frameLength
        memcpy(mono.floatChannelData![0], samples, frames * 4)
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        guard out.frameLength > 0 else { return }
        send(.mic, Data(bytes: out.floatChannelData![0], count: Int(out.frameLength) * 4))
    }
}
