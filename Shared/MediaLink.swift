import Foundation
import Network

/// Fork-only side channel for sound, microphone and camera between a Mac
/// sender and a Mac receiver. It is its own TCP connection on the receiver's
/// display port + 2, so it never touches the display protocol: a stock
/// receiver simply refuses the dial and nothing else changes.
///
/// Frame: [4-byte big-endian length of tag+payload][4-byte ASCII tag][payload]
///   ODAU sender -> receiver  sound: Float32 planar PCM, 48 kHz, 2 channels
///   ODMI receiver -> sender  mic:   Float32 PCM, 48 kHz, 1 channel
///   ODCM receiver -> sender  camera: H.264 Annex B access unit
///   ODCT sender -> receiver  control JSON, e.g. {"mic":true,"camera":false}
enum MediaTag: String {
    case sound = "ODAU", mic = "ODMI", camera = "ODCM", control = "ODCT"
}

enum MediaLink {
    static let portOffset: UInt16 = 2
    static let sampleRate: Double = 48_000

    static func frame(_ tag: MediaTag, _ payload: Data) -> Data {
        var out = Data(capacity: 8 + payload.count)
        var length = UInt32(4 + payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(contentsOf: Array(tag.rawValue.utf8))
        out.append(payload)
        return out
    }

    /// Read frames until the connection ends. `onFrame` runs on the
    /// connection's queue. Unknown tags are skipped so either side can grow.
    static func receive(on conn: NWConnection,
                        onFrame: @escaping (MediaTag, Data) -> Void,
                        onEnd: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else { onEnd(); return }
            let length = header.reduce(0) { Int($0) << 8 | Int($1) }
            // ponytail: 16 MB cap, a camera keyframe is well under 1 MB.
            guard length >= 4, length < 16 << 20 else { conn.cancel(); onEnd(); return }
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body, body.count == length else { onEnd(); return }
                let tagText = String(decoding: body.prefix(4), as: UTF8.self)
                if let tag = MediaTag(rawValue: tagText) {
                    onFrame(tag, Data(body.dropFirst(4)))
                }
                receive(on: conn, onFrame: onFrame, onEnd: onEnd)
            }
        }
    }
}
