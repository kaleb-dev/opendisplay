import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

/// Receiver half of the fork's camera: this Mac's camera, scaled to
/// CameraFormat and H.264-encoded, handed to `onPayload` as ODCM payloads.
/// Runs only while the sender asks for it.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "opendisplay.camera.capture")
    private var session: AVCaptureSession?
    private var encoder: CameraEncoder?
    #if os(iOS)
    private var output: AVCaptureVideoDataOutput?
    private var orientationObserver: NSObjectProtocol?

    /// The front camera's frames come in the sensor's fixed orientation;
    /// turn them upright for how the iPad is held right now.
    /// ponytail: portrait frames get squeezed into the landscape 1280x720 camera.
    private func applyOrientation() {
        DispatchQueue.main.async { [weak self] in
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let orientation: AVCaptureVideoOrientation
            switch scene?.interfaceOrientation {
            case .landscapeLeft: orientation = .landscapeLeft
            case .portrait: orientation = .portrait
            case .portraitUpsideDown: orientation = .portraitUpsideDown
            default: orientation = .landscapeRight
            }
            self?.queue.async {
                guard let connection = self?.output?.connection(with: .video),
                      connection.isVideoOrientationSupported else { return }
                connection.videoOrientation = orientation
            }
        }
    }
    #endif
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
        #if os(iOS)
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        #else
        let camera = AVCaptureDevice.default(for: .video)
        #endif
        guard session == nil, let device = camera,
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.info("camera: no camera available")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let output = AVCaptureVideoDataOutput()
        #if os(iOS)
        // iOS rejects size keys in videoSettings; the preset sets the size
        // and the encoder scales anything else to CameraFormat.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        #else
        session.sessionPreset = .high
        // AVFoundation scales to the fixed size the virtual camera declares.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: CameraFormat.width,
            kCVPixelBufferHeightKey as String: CameraFormat.height,
        ]
        #endif
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            Log.info("camera: cannot configure capture")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        #if os(iOS)
        self.output = output
        applyOrientation()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyOrientation()
        }
        #endif
        encoder = CameraEncoder(onPayload: onPayload)
        session.startRunning()
        self.session = session
        Log.info("camera: capture started (\(device.localizedName))")
    }

    private func stopOnQueue() {
        guard let session else { return }
        #if os(iOS)
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        orientationObserver = nil
        #endif
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
