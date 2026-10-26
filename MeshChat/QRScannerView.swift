import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Full-screen camera scanner for the invite/reply QR codes shown by
/// InternetLinkView. Calls `onCode` once with the first QR code it reads and
/// then dismisses itself. Nothing is recorded or saved.
struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationStack {
            ZStack {
                if cameraUnavailable {
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "camera.fill",
                        description: Text("Allow camera access for MeshChat in Settings, or paste the code instead.")
                    )
                } else {
                    ScannerRepresentable(
                        onCode: { code in
                            onCode(code)
                            dismiss()
                        },
                        onUnavailable: { cameraUnavailable = true }
                    )
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("Point the camera at the QR code")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Scan QR Code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

// MARK: - Capture

/// Owns the AVCaptureSession and reports the first QR code seen.
final class QRScannerCore: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?
    private var delivered = false
    private let queue = DispatchQueue(label: "app-chat.qr-scan")

    func configure() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        return true
    }

    func start() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let text = object.stringValue else { return }
        delivered = true
        onCode?(text)
    }
}

/// Asks for camera permission if needed, then wires the capture session to
/// the platform's preview layer.
final class ScannerCoordinator {
    let core = QRScannerCore()

    func start(
        previewLayer: AVCaptureVideoPreviewLayer?,
        onCode: @escaping (String) -> Void,
        onUnavailable: @escaping () -> Void
    ) {
        let begin = { [core] in
            guard core.configure() else {
                onUnavailable()
                return
            }
            previewLayer?.session = core.session
            previewLayer?.videoGravity = .resizeAspectFill
            core.onCode = onCode
            core.start()
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { begin() } else { onUnavailable() }
                }
            }
        default:
            onUnavailable()
        }
    }

    func stop() {
        core.stop()
    }
}

// MARK: - Platform previews

#if os(iOS)
final class ScannerPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}

private struct ScannerRepresentable: UIViewRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> ScannerCoordinator { ScannerCoordinator() }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        context.coordinator.start(previewLayer: view.previewLayer, onCode: onCode, onUnavailable: onUnavailable)
        return view
    }

    func updateUIView(_ uiView: ScannerPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: ScannerCoordinator) {
        coordinator.stop()
    }
}
#elseif os(macOS)
final class ScannerPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer = previewLayer
        wantsLayer = true
    }
}

private struct ScannerRepresentable: NSViewRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> ScannerCoordinator { ScannerCoordinator() }

    func makeNSView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        context.coordinator.start(previewLayer: view.previewLayer, onCode: onCode, onUnavailable: onUnavailable)
        return view
    }

    func updateNSView(_ nsView: ScannerPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: ScannerPreviewView, coordinator: ScannerCoordinator) {
        coordinator.stop()
    }
}
#endif
