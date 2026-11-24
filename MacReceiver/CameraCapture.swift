import AVFoundation
import Foundation

/// Receiver half of the fork's camera: this Mac's camera, scaled to
/// CameraFormat and H.264-encoded, handed to `onPayload` as ODCM payloads.
/// Runs only while the sender asks for it.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "opendisplay.camera.capture")
    private var session: AVCaptureSession?
    private var encoder: CameraEncoder?
    private let onPayload: (Data) -> Void

    init(onPayload: @escaping (Data) -> Void) {
        self.onPayload = onPayload
    }

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            if !running { stopOnQueue(); return }
            guard session == nil else { return }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async {
                    guard granted else { Log.info("camera: access denied"); return }
                    self.startOnQueue()
                }
            }
        }
    }

    private func startOnQueue() {
        guard session == nil, let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.info("camera: no camera available")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        let output = AVCaptureVideoDataOutput()
        // AVFoundation scales to the fixed size the virtual camera declares.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: CameraFormat.width,
            kCVPixelBufferHeightKey as String: CameraFormat.height,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            Log.info("camera: cannot configure capture")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        encoder = CameraEncoder(onPayload: onPayload)
        session.startRunning()
        self.session = session
        Log.info("camera: capture started (\(device.localizedName))")
    }

    private func stopOnQueue() {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        encoder = nil
        Log.info("camera: capture stopped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder?.encode(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
