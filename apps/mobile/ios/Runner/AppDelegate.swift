import UIKit
import Flutter

class CameraPreviewTexture: NSObject, FlutterTexture {
    private var pixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    func updateBuffer(_ newBuffer: CVPixelBuffer) {
        lock.lock()
        pixelBuffer = newBuffer
        lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer = pixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var captureEngine: CameraCaptureEngine?
    private var hardwareEncoder: HardwareEncoder?
    private var videoServer: VideoStreamingServer?
    private var eventSink: FlutterEventSink?

    private var previewTexture: CameraPreviewTexture?
    private var textureId: Int64 = -1
    private weak var flutterController: FlutterViewController?

    private var currentLens = "back_wide"
    private var currentWidth = 1920
    private var currentHeight = 1080
    private var currentFps = 30

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return result
        }
        self.flutterController = controller

        // Register Metal preview texture
        let texture = CameraPreviewTexture()
        self.previewTexture = texture
        self.textureId = controller.register(texture)

        // Initialize Native Video Streaming Server on port 8282
        if videoServer == nil {
            videoServer = VideoStreamingServer(port: 8282)
            videoServer?.start()
        }

        let cameraChannel = FlutterMethodChannel(name: "com.camsync/camera", binaryMessenger: controller.binaryMessenger)
        let streamChannel = FlutterEventChannel(name: "com.camsync/video_stream", binaryMessenger: controller.binaryMessenger)

        streamChannel.setStreamHandler(self)
        captureEngine = CameraCaptureEngine()

        cameraChannel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }

            switch call.method {
            case "startCapture":
                let args = call.arguments as? [String: Any]
                let width = (args?["width"] as? Int) ?? 1920
                let height = (args?["height"] as? Int) ?? 1080
                let fps = (args?["fps"] as? Int) ?? 30
                let lens = (args?["lens"] as? String) ?? "back_wide"

                self.currentWidth = width
                self.currentHeight = height
                self.currentFps = fps
                self.currentLens = lens

                if self.videoServer == nil {
                    self.videoServer = VideoStreamingServer(port: 8282)
                    self.videoServer?.start()
                }

                self.hardwareEncoder?.stop()
                self.hardwareEncoder = HardwareEncoder(width: Int32(width), height: Int32(height), fps: Int32(fps)) { [weak self] packetData in
                    self?.videoServer?.broadcastPacket(packetData)
                }

                self.captureEngine?.onFrameCaptured = { [weak self] pixelBuffer, pts in
                    guard let self = self else { return }
                    self.previewTexture?.updateBuffer(pixelBuffer)
                    if self.textureId >= 0 {
                        self.flutterController?.textureFrameAvailable(self.textureId)
                    }

                    let actualW = Int32(CVPixelBufferGetWidth(pixelBuffer))
                    let actualH = Int32(CVPixelBufferGetHeight(pixelBuffer))

                    if self.hardwareEncoder == nil || self.hardwareEncoder?.width != actualW || self.hardwareEncoder?.height != actualH {
                        self.hardwareEncoder?.stop()
                        self.hardwareEncoder = HardwareEncoder(width: actualW, height: actualH, fps: Int32(self.currentFps)) { [weak self] packetData in
                            self?.videoServer?.broadcastPacket(packetData)
                        }
                    }

                    self.hardwareEncoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
                }

                self.captureEngine?.startCapture(lens: lens, width: Int32(width), height: Int32(height), fps: Int32(fps)) { [weak self] success in
                    guard let self = self else { return }
                    result([
                        "success": success,
                        "textureId": self.textureId
                    ])
                }

            case "stopCapture":
                self.captureEngine?.stop()
                self.hardwareEncoder?.stop()
                self.hardwareEncoder = nil
                result(true)

            case "setLens":
                let args = call.arguments as? [String: Any]
                let lens = (args?["lens"] as? String) ?? "back_wide"
                self.currentLens = lens

                if self.hardwareEncoder != nil {
                    self.captureEngine?.startCapture(lens: lens, width: Int32(self.currentWidth), height: Int32(self.currentHeight), fps: Int32(self.currentFps)) { [weak self] success in
                        guard let self = self else { return }
                        result([
                            "success": success,
                            "textureId": self.textureId
                        ])
                    }
                } else {
                    result(true)
                }

            case "setTorch":
                let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                self.captureEngine?.setTorch(enabled: enabled)
                result(true)

            case "setZoom":
                let zoom = (call.arguments as? [String: Any])?["zoom"] as? Double ?? 1.0
                self.captureEngine?.setZoom(zoom: CGFloat(zoom))
                result(true)

            case "setFocus":
                let args = call.arguments as? [String: Any]
                let mode = (args?["mode"] as? String) ?? "auto"
                let dist = Float((args?["distance"] as? Double) ?? 0.0)
                self.captureEngine?.setFocus(mode: mode, distance: dist)
                result(true)

            case "setExposure":
                result(true)

            case "setWhiteBalance":
                result(true)

            case "setOrientation":
                let args = call.arguments as? [String: Any]
                let orientation = (args?["orientation"] as? String) ?? "landscapeRight"
                self.captureEngine?.setOrientation(mode: orientation)
                result(true)

            case "applyParameters":
                let args = call.arguments as? [String: Any]
                if let torch = args?["torch"] as? Bool { self.captureEngine?.setTorch(enabled: torch) }
                if let zoom = args?["zoom"] as? Double { self.captureEngine?.setZoom(zoom: CGFloat(zoom)) }
                result(true)

            case "getSystemStats":
                UIDevice.current.isBatteryMonitoringEnabled = true
                let rawBat = UIDevice.current.batteryLevel
                let batPct = rawBat >= 0 ? Int(rawBat * 100) : 100
                let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
                var thermalStateStr = "nominal"
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thermalStateStr = "nominal"
                case .fair: thermalStateStr = "fair"
                case .serious: thermalStateStr = "serious"
                case .critical: thermalStateStr = "critical"
                @unknown default: thermalStateStr = "nominal"
                }
                result([
                    "batteryLevel": batPct,
                    "isCharging": isCharging,
                    "thermalState": thermalStateStr,
                    "temperatureC": 30.0,
                    "fps": Double(self.currentFps),
                    "bitrateKbps": 4000
                ])

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return result
    }
}

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
