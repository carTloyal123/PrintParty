//
//  QRScannerView.swift
//  PrintParty
//
//  SwiftUI wrapper around AVCaptureSession for scanning a gateway pairing QR.
//  Parses `printparty://pair?url=...&code=...` and reports (url, code) back.
//  Handles the camera-permission lifecycle: if access is denied, it reports
//  via `onPermissionDenied` so the caller can offer "Open Settings".
//

import SwiftUI
import AVFoundation
import UIKit
import PrintPartyKit

struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: (_ url: String, _ code: String) -> Void
    /// Called when camera access is unavailable (denied/restricted).
    var onPermissionDenied: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScanned = { url, code in
            onScanned(url, code)
            dismiss()
        }
        vc.onPermissionDenied = onPermissionDenied
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((_ url: String, _ code: String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.clengineering.PrintParty.qr.session")
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessAndConfigure()
    }

    // MARK: - Permission

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.onPermissionDenied?()
                    }
                }
            }
        case .denied, .restricted:
            onPermissionDenied?()
        @unknown default:
            onPermissionDenied?()
        }
    }

    // MARK: - Camera setup

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onPermissionDenied?()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onPermissionDenied?()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        captureSession = session
        sessionQueue.async { session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session = captureSession, session.isRunning {
            sessionQueue.async { session.stopRunning() }
        }
    }

    // MARK: - Scanning

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue,
              let payload = PairingDeepLink.parse(string)
        else { return }

        hasScanned = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "QR code scanned successfully")
        onScanned?(payload.url, payload.code)
    }
}
