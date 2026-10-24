package com.camsync.mobile

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "CamSyncMain"
    }

    private val CAMERA_CHANNEL = "com.camsync/camera"
    private val STREAM_CHANNEL = "com.camsync/video_stream"

    private var captureEngine: CameraCaptureEngine? = null
    private var hardwareEncoder: HardwareEncoder? = null
    private var eventSink: EventChannel.EventSink? = null

    private var currentLens = "back_wide"
    private var currentWidth = 1920
    private var currentHeight = 1080
    private var currentFps = 30

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        captureEngine = CameraCaptureEngine(applicationContext)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.i(TAG, "Video stream event channel subscribed")
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    Log.i(TAG, "Video stream event channel cancelled")
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "startCapture" -> {
                        val width = call.argument<Int>("width") ?: 1920
                        val height = call.argument<Int>("height") ?: 1080
                        val fps = call.argument<Int>("fps") ?: 30
                        val lens = call.argument<String>("lens") ?: "back_wide"

                        startStreaming(width, height, fps, lens, result)
                    }
                    "stopCapture" -> {
                        stopStreaming()
                        result.success(true)
                    }
                    "setLens" -> {
                        val lens = call.argument<String>("lens") ?: "back_wide"
                        Log.i(TAG, "setLens requested: $lens")
                        currentLens = lens
                        if (hardwareEncoder != null) {
                            startStreaming(currentWidth, currentHeight, currentFps, currentLens, result)
                        } else {
                            result.success(true)
                        }
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
                    "setOrientation" -> {
                        result.success(true)
                    }
                    "applyParameters" -> {
                        call.argument<Boolean>("torch")?.let { captureEngine?.setTorch(it) }
                        call.argument<Double>("zoom")?.let { captureEngine?.setZoom(it.toFloat()) }
                        result.success(true)
                    }
                    else -> {
                        Log.w(TAG, "Unhandled method: ${call.method}")
                        result.notImplemented()
                    }
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
        Log.i(TAG, "Starting streaming: ${width}x${height} @ ${fps}fps, lens=$lens")
        stopStreaming()

        currentWidth = width
        currentHeight = height
        currentFps = fps
        currentLens = lens

        captureEngine?.startCapture(
            lens = lens,
            requestedWidth = width,
            requestedHeight = height,
            requestedFps = fps,
            onActualDimensions = { actualWidth, actualHeight, actualFps ->
                Log.i(TAG, "Creating HardwareEncoder: ${actualWidth}x${actualHeight} @ ${actualFps}fps")
                hardwareEncoder = HardwareEncoder(
                    width = actualWidth,
                    height = actualHeight,
                    fps = actualFps,
                    onPacketEncoded = { packetBytes ->
                        runOnUiThread {
                            eventSink?.success(packetBytes)
                        }
                    }
                )
                hardwareEncoder!!.start()
            },
            onFrame = { nv21Data ->
                hardwareEncoder?.encodeFrame(nv21Data)
            },
            onStarted = {
                CamSyncForegroundService.start(applicationContext)
                runOnUiThread {
                    Log.i(TAG, "startStreaming success!")
                    result.success(true)
                }
            }
        )
    }

    private fun stopStreaming() {
        Log.i(TAG, "Stopping streaming...")
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
