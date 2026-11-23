import AVFoundation
import SwiftUI
import UIKit

/// Front-camera photo for camera questions ("What's this?", "Read this"). The photo is made smaller,
/// sent to the AI on your PC with the question, and never saved on the iPhone.
final class PhotoCapture: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published private(set) var ready = false
    @Published private(set) var denied = false
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "photo.capture")
    private var configured = false
    private var completion: ((Data?) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.run() } else { self.denied = true }
                }
            }
        default:
            denied = true
        }
    }

    private func run() {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.ready = running }
        }
    }

    func stop() {
        ready = false
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture(completion: @escaping (Data?) -> Void) {
        self.completion = completion
        let orientation = Self.currentOrientation
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { self.finish(nil) }
                return
            }
            if let connection = self.output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation().flatMap { Self.shrink($0) }
        DispatchQueue.main.async { self.finish(data) }
    }

    private func finish(_ data: Data?) {
        let callback = completion
        completion = nil
        callback?(data)
    }

    /// 1024 px on the long side, JPEG: small enough to send quickly, sharp enough to read a label.
    static func shrink(_ data: Data, maxSide: CGFloat = 1024) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))      // also turns it the right way up
        }
        return resized.jpegData(compressionQuality: 0.6)
    }

    /// The app is landscape-only: match the camera to the way the iPhone is standing.
    static var currentOrientation: AVCaptureVideoOrientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.interfaceOrientation {
        case .landscapeLeft?: return .landscapeLeft
        case .landscapeRight?: return .landscapeRight
        case .portraitUpsideDown?: return .portraitUpsideDown
        default: return .portrait
        }
    }
}

/// Live front-camera preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.matchOrientation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            matchOrientation()
        }

        func matchOrientation() {
            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = PhotoCapture.currentOrientation
            }
        }
    }
}
