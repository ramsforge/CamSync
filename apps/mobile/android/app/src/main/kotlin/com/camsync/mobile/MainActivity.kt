package com.camsync.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CAMERA_CHANNEL = "com.camsync/camera"
    private val STREAM_CHANNEL = "com.camsync/video_stream"

    private var captureEngine: CameraCaptureEngine? = null
    private var hardwareEncoder: HardwareEncoder? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        captureEngine = CameraCaptureEngine(applicationContext)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "startCapture" -> {
                        val width = call.argument<Int>("width") ?: 1920
                        val height = call.argument<Int>("height") ?: 1080
                        val fps = call.argument<Int>("fps") ?: 60
                        val lens = call.argument<String>("lens") ?: "back_wide"

                        startStreaming(width, height, fps, lens, result)
                    }
                    "stopCapture" -> {
                        stopStreaming()
                        result.success(true)
                    }
                    "setTorch" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        captureEngine?.setTorch(enabled)
                        result.success(true)
                    }
                    "setZoom" -> {
                        val zoom = (call.argument<Double>("zoom") ?: 1.0).toFloat()
                        captureEngine?.setZoom(zoom)
                        result.success(true)
                    }
                    "setFocus" -> {
                        val mode = call.argument<String>("mode") ?: "auto"
                        val dist = (call.argument<Double>("distance") ?: 0.0).toFloat()
                        captureEngine?.setFocus(mode, dist)
                        result.success(true)
                    }
                    "setExposure" -> {
                        val mode = call.argument<String>("mode") ?: "auto"
                        val iso = call.argument<Int>("iso")
                        val shutter = call.argument<Double>("shutterSpeedMs")
                        captureEngine?.setExposure(mode, iso, shutter)
                        result.success(true)
                    }
                    "setWhiteBalance" -> {
                        val mode = call.argument<String>("mode") ?: "auto"
                        captureEngine?.setWhiteBalance(mode)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startStreaming(
        width: Int,
        height: Int,
        fps: Int,
        lens: String,
        result: MethodChannel.Result
    ) {
        stopStreaming()

        hardwareEncoder = HardwareEncoder(
            width = width,
            height = height,
            fps = fps,
            onPacketEncoded = { packetBytes ->
                runOnUiThread {
                    eventSink?.success(packetBytes)
                }
            }
        )

        val surface = hardwareEncoder!!.start()

        captureEngine?.startCapture(surface, lens) {
            CamSyncForegroundService.start(applicationContext)
            runOnUiThread {
                result.success(true)
            }
        }
    }

    private fun stopStreaming() {
        CamSyncForegroundService.stop(applicationContext)
        captureEngine?.stop()
        hardwareEncoder?.stop()
        hardwareEncoder = null
    }

    override fun onDestroy() {
        stopStreaming()
        super.onDestroy()
    }
}
