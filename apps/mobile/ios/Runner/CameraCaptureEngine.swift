import Foundation
import AVFoundation

class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private var activeDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let videoQueue = DispatchQueue(label: "com.camsync.videoQueue", qos: .userInteractive)

    var onFrameCaptured: ((CVPixelBuffer, CMTime) -> Void)?

    func startCapture(lens: String, width: Int32 = 1920, height: Int32 = 1080, fps: Int32 = 30, completion: @escaping (Bool) -> Void) {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            self.configureAndStart(lens: lens, width: width, height: height, fps: fps, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStart(lens: lens, width: width, height: height, fps: fps, completion: completion)
                    } else {
                        completion(false)
                    }
                }
            }
        default:
            completion(false)
        }
    }

    private func configureAndStart(lens: String, width: Int32, height: Int32, fps: Int32, completion: @escaping (Bool) -> Void) {
        captureSession.beginConfiguration()

        // Choose sessionPreset dynamically based on requested resolution
        if (width >= 3840 || height >= 2160) && captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else if (width >= 1920 || height >= 1080) && captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else if (width >= 1280 || height >= 720) && captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        } else {
            captureSession.sessionPreset = .high
        }

        // Clean up previous inputs and outputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        let deviceType: AVCaptureDevice.DeviceType
        var position: AVCaptureDevice.Position = .back

        switch lens {
        case "front":
            deviceType = .builtInWideAngleCamera
            position = .front
        case "back_ultra_wide":
            deviceType = .builtInUltraWideCamera
            position = .back
        case "back_telephoto":
            deviceType = .builtInTelephotoCamera
            position = .back
        default:
            deviceType = .builtInWideAngleCamera
            position = .back
        }

        var candidateTypes: [AVCaptureDevice.DeviceType] = [deviceType]
        if deviceType != .builtInWideAngleCamera {
            candidateTypes.append(.builtInWideAngleCamera)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: candidateTypes,
            mediaType: .video,
            position: position
        )

        guard let device = discoverySession.devices.first else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { completion(false) }
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
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.setSampleBufferDelegate(self, queue: videoQueue)

            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            videoOutput = output

            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    // When requested width >= height, use landscapeRight for standard 16:9 widescreen webcam (no stretching!)
                    if width >= height {
                        connection.videoOrientation = .landscapeRight
                    } else {
                        connection.videoOrientation = .portrait
                    }
                }
                if position == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }

            // Configure frame rate safely against supported ranges to prevent NSInvalidArgumentException
            do {
                try device.lockForConfiguration()
                let targetFps = Double(fps)
                var supportedRange: AVFrameRateRange?
                for range in device.activeFormat.videoSupportedFrameRateRanges {
                    if targetFps >= range.minFrameRate && targetFps <= range.maxFrameRate {
                        supportedRange = range
                        break
                    }
                }

                if let range = supportedRange {
                    let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                } else if let fallbackRange = device.activeFormat.videoSupportedFrameRateRanges.first {
                    let clampedFps = min(max(targetFps, fallbackRange.minFrameRate), fallbackRange.maxFrameRate)
                    let duration = CMTime(value: 1, timescale: CMTimeScale(clampedFps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
                device.unlockForConfiguration()
            } catch {
                print("[CameraCaptureEngine] Could not lock device for frame rate configuration: \(error)")
            }

            captureSession.commitConfiguration()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if !(self?.captureSession.isRunning ?? false) {
                    self?.captureSession.startRunning()
                }
                DispatchQueue.main.async { completion(true) }
            }
        } catch {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { completion(false) }
        }
    }

    func setOrientation(mode: String) {
        guard let output = videoOutput, let connection = output.connection(with: .video), connection.isVideoOrientationSupported else { return }
        switch mode {
        case "portrait":
            connection.videoOrientation = .portrait
        case "landscapeLeft":
            connection.videoOrientation = .landscapeLeft
        case "landscapeRight":
            connection.videoOrientation = .landscapeRight
        default:
            connection.videoOrientation = .landscapeRight
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
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
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
