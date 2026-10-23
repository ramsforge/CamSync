import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var captureEngine: CameraCaptureEngine?
    private var hardwareEncoder: HardwareEncoder?
    private var eventSink: FlutterEventSink?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        let cameraChannel = FlutterMethodChannel(name: "com.camsync/camera", binaryMessenger: controller.binaryMessenger)
        let streamChannel = FlutterEventChannel(name: "com.camsync/video_stream", binaryMessenger: controller.binaryMessenger)

        streamChannel.setStreamHandler(self)

        captureEngine = CameraCaptureEngine()

        cameraChannel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }

            switch call.method {
            case "startCapture":
                let args = call.arguments as? [String: Any]
                let width = (args?["width"] as? Int32) ?? 1920
                let height = (args?["height"] as? Int32) ?? 1080
                let fps = (args?["fps"] as? Int32) ?? 60
                let lens = (args?["lens"] as? String) ?? "back_wide"

                self.hardwareEncoder = HardwareEncoder(width: width, height: height, fps: fps) { [weak self] packetData in
                    DispatchQueue.main.async {
                        self?.eventSink?(FlutterStandardTypedData(bytes: packetData))
                    }
                }

                self.captureEngine?.onFrameCaptured = { [weak self] pixelBuffer, pts in
                    self?.hardwareEncoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
                }

                self.captureEngine?.startCapture(lens: lens, fps: fps) { success in
                    result(success)
                }

            case "stopCapture":
                self.captureEngine?.stop()
                self.hardwareEncoder?.stop()
                self.hardwareEncoder = nil
                result(true)

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

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
