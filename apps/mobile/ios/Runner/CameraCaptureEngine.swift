import Foundation
import AVFoundation

class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private var activeDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let videoQueue = DispatchQueue(label: "com.camsync.videoQueue", qos: .userInteractive)

    var onFrameCaptured: ((CVPixelBuffer, CMTime) -> Void)?

    func startCapture(lens: String, fps: Int32 = 60, completion: @escaping (Bool) -> Void) {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        let deviceType: AVCaptureDevice.DeviceType
        var position: AVCaptureDevice.Position = .back

        switch lens {
        case "front":
            deviceType = .builtInWideAngleCamera
            position = .front
        case "back_ultra_wide":
            deviceType = .builtInUltraWideCamera
        case "back_telephoto":
            deviceType = .builtInTelephotoCamera
        default:
            deviceType = .builtInWideAngleCamera
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [deviceType, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )

        guard let device = discoverySession.devices.first else {
            captureSession.commitConfiguration()
            completion(false)
            return
        }

        activeDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)

            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            videoOutput = output

            // Configure Frame Rate
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            device.unlockForConfiguration()

            captureSession.commitConfiguration()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
                DispatchQueue.main.async { completion(true) }
            }
        } catch {
            captureSession.commitConfiguration()
            completion(false)
        }
    }

    func setTorch(enabled: Bool) {
        guard let device = activeDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    func setZoom(zoom: CGFloat) {
        guard let device = activeDevice else { return }
        try? device.lockForConfiguration()
        let factor = max(device.minAvailableVideoZoomFactor, min(zoom, device.maxAvailableVideoZoomFactor))
        device.videoZoomFactor = factor
        device.unlockForConfiguration()
    }

    func setFocus(mode: String, distance: Float) {
        guard let device = activeDevice, device.isFocusModeSupported(.continuousAutoFocus) else { return }
        try? device.lockForConfiguration()
        if mode == "manual" && device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: distance, completionHandler: nil)
        } else {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()
    }

    func stop() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        activeDevice = nil
        videoOutput = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrameCaptured?(pixelBuffer, pts)
    }
}
