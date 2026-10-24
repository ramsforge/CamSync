package com.camsync.mobile

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "CamSyncMain"
    }

    private val CAMERA_CHANNEL = "com.camsync/camera"
    private val STREAM_CHANNEL = "com.camsync/video_stream"

    private var captureEngine: CameraCaptureEngine? = null
    private var hardwareEncoder: HardwareEncoder? = null
    private var videoServer: VideoStreamingServer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null

    private var currentLens = "back_wide"
    private var currentWidth = 1920
    private var currentHeight = 1080
    private var currentFps = 30
    private var currentOrientation = "landscapeLeft"

    private var pendingWidth = 1920
    private var pendingHeight = 1080
    private var pendingFps = 30
    private var pendingLens = "back_wide"
    private var pendingResult: MethodChannel.Result? = null
    private val REQUEST_CAMERA_CODE = 1001

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CAMERA_CODE) {
            val res = pendingResult ?: return
            pendingResult = null
            if (grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                Log.i(TAG, "Camera permission granted by user! Starting stream...")
                startStreaming(pendingWidth, pendingHeight, pendingFps, pendingLens, res)
            } else {
                Log.w(TAG, "Camera permission denied by user.")
                res.success(mapOf("success" to false, "error" to "Camera permission denied"))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        captureEngine = CameraCaptureEngine(applicationContext)
        if (videoServer == null) {
            videoServer = VideoStreamingServer(8282).apply { start() }
        }

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

                        if (checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            Log.i(TAG, "Camera permission not granted. Prompting user...")
                            pendingWidth = width
                            pendingHeight = height
                            pendingFps = fps
                            pendingLens = lens
                            pendingResult = result
                            requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQUEST_CAMERA_CODE)
                        } else {
                            startStreaming(width, height, fps, lens, result)
                        }
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
                        val orientation = call.argument<String>("orientation") ?: "landscapeLeft"
                        Log.i(TAG, "setOrientation requested: $orientation")
                        val changed = (orientation != currentOrientation)
                        currentOrientation = orientation
                        if (changed && hardwareEncoder != null) {
                            startStreaming(currentWidth, currentHeight, currentFps, currentLens, result)
                        } else {
                            result.success(true)
                        }
                    }
                    "applyParameters" -> {
                        call.argument<Boolean>("torch")?.let { captureEngine?.setTorch(it) }
                        call.argument<Double>("zoom")?.let { captureEngine?.setZoom(it.toFloat()) }
                        result.success(true)
                    }
                    "getSystemStats" -> {
                        result.success(getSystemStats())
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

        if (videoServer == null) {
            videoServer = VideoStreamingServer(8282).apply { start() }
        }

        val entry = flutterEngine?.renderer?.createSurfaceTexture()
        textureEntry = entry
        val surfaceTexture = entry?.surfaceTexture()
        val textureId = entry?.id() ?: 0L

        val isPortrait = (currentOrientation == "portrait")
        captureEngine?.startCapture(
            lens = lens,
            requestedWidth = width,
            requestedHeight = height,
            requestedFps = fps,
            previewSurfaceTexture = surfaceTexture,
            onActualDimensions = { actualWidth, actualHeight, actualFps ->
                val encWidth = if (isPortrait) actualHeight else actualWidth
                val encHeight = if (isPortrait) actualWidth else actualHeight
                Log.i(TAG, "Creating HardwareEncoder: ${encWidth}x${encHeight} (portrait=$isPortrait) @ ${actualFps}fps")
                hardwareEncoder = HardwareEncoder(
                    width = encWidth,
                    height = encHeight,
                    fps = actualFps,
                    isPortrait = isPortrait,
                    cameraWidth = actualWidth,
                    cameraHeight = actualHeight,
                    onPacketEncoded = { packetBytes ->
                        videoServer?.broadcastPacket(packetBytes)
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
                    Log.i(TAG, "startStreaming success! textureId=$textureId")
                    result.success(mapOf("success" to true, "textureId" to textureId))
                }
            },
            onError = { errMsg ->
                runOnUiThread {
                    Log.e(TAG, "startStreaming failed: $errMsg")
                    result.success(mapOf("success" to false, "error" to errMsg))
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
        try {
            textureEntry?.release()
        } catch (_: Exception) {}
        textureEntry = null
    }

    private fun getSystemStats(): Map<String, Any> {
        var batteryLevel = 100
        var isCharging = false
        var temperatureC = 25.0
        var thermalState = "nominal"

        try {
            val intent = applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (intent != null) {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) {
                    batteryLevel = (level * 100) / scale
                }
                val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                             status == BatteryManager.BATTERY_STATUS_FULL
                val rawTemp = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0)
                if (rawTemp > 0) {
                    temperatureC = rawTemp / 10.0
                }
            }
        } catch (_: Exception) {}

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                thermalState = when (powerManager?.currentThermalStatus) {
                    PowerManager.THERMAL_STATUS_NONE -> "nominal"
                    PowerManager.THERMAL_STATUS_LIGHT -> "fair"
                    PowerManager.THERMAL_STATUS_MODERATE -> "fair"
                    PowerManager.THERMAL_STATUS_SEVERE -> "serious"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "critical"
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
                    else -> "nominal"
                }
            }
        } catch (_: Exception) {}

        val encStats = hardwareEncoder?.getStats() ?: mapOf("fps" to 0.0, "bitrateKbps" to 0)

        return mapOf(
            "batteryLevel" to batteryLevel,
            "isCharging" to isCharging,
            "temperatureC" to temperatureC,
            "thermalState" to thermalState,
            "fps" to (encStats["fps"] ?: 0.0),
            "bitrateKbps" to (encStats["bitrateKbps"] ?: 0)
        )
    }

    override fun onDestroy() {
        stopStreaming()
        videoServer?.stop()
        videoServer = null
        super.onDestroy()
    }
}
