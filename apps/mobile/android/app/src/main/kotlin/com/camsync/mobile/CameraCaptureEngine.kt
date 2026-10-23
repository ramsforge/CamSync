package com.camsync.mobile

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.*
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

class CameraCaptureEngine(private val context: Context) {
    private val cameraManager: CameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewRequestBuilder: CaptureRequest.Builder? = null

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private val cameraOpenCloseLock = Semaphore(1)

    private var currentCameraId: String = "0"
    private var currentTorch = false
    private var currentZoom = 1.0f

    init {
        startBackgroundThread()
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("CamSyncCameraThread").apply { start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
            backgroundThread = null
            backgroundHandler = null
        } catch (_: InterruptedException) {}
    }

    private fun selectCameraId(lens: String): String {
        val ids = cameraManager.cameraIdList
        for (id in ids) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)

            if (lens == "front" && facing == CameraCharacteristics.LENS_FACING_FRONT) {
                return id
            }
            if (lens.startsWith("back") && facing == CameraCharacteristics.LENS_FACING_BACK) {
                // Check for ultra-wide lens (focal length < 2.5mm or wide FOV)
                if (lens == "back_ultra_wide") {
                    val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    if (focalLengths != null && focalLengths.isNotEmpty() && focalLengths[0] < 2.5f) {
                        return id
                    }
                } else if (lens == "back_wide") {
                    return id
                }
            }
        }
        return ids.firstOrNull() ?: "0"
    }

    @SuppressLint("MissingPermission")
    fun startCapture(encoderSurface: Surface, lens: String, onStarted: () -> Unit) {
        if (!cameraOpenCloseLock.tryAcquire(2500, TimeUnit.MILLISECONDS)) {
            return
        }

        currentCameraId = selectCameraId(lens)

        cameraManager.openCamera(currentCameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraOpenCloseLock.release()
                cameraDevice = camera
                createCaptureSession(camera, encoderSurface, onStarted)
            }

            override fun onDisconnected(camera: CameraDevice) {
                cameraOpenCloseLock.release()
                camera.close()
                cameraDevice = null
            }

            override fun onError(camera: CameraDevice, error: Int) {
                cameraOpenCloseLock.release()
                camera.close()
                cameraDevice = null
            }
        }, backgroundHandler)
    }

    private fun createCaptureSession(
        camera: CameraDevice,
        encoderSurface: Surface,
        onStarted: () -> Unit
    ) {
        try {
            previewRequestBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(encoderSurface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            }

            camera.createCaptureSession(
                listOf(encoderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            previewRequestBuilder?.let {
                                session.setRepeatingRequest(it.build(), null, backgroundHandler)
                            }
                            onStarted()
                        } catch (_: Exception) {}
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {}
                },
                backgroundHandler
            )
        } catch (_: Exception) {}
    }

    fun setTorch(enabled: Boolean) {
        currentTorch = enabled
        previewRequestBuilder?.let { builder ->
            builder.set(
                CaptureRequest.FLASH_MODE,
                if (enabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
            )
            updateRepeating()
        }
    }

    fun setZoom(zoom: Float) {
        currentZoom = zoom
        previewRequestBuilder?.let { builder ->
            try {
                builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
                updateRepeating()
            } catch (_: Exception) {}
        }
    }

    fun setFocus(mode: String, distance: Float) {
        previewRequestBuilder?.let { builder ->
            if (mode == "manual") {
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, distance * 10.0f) // Diopters
            } else {
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            }
            updateRepeating()
        }
    }

    fun setExposure(mode: String, iso: Int?, shutterSpeedMs: Double?) {
        previewRequestBuilder?.let { builder ->
            if (mode == "manual" && iso != null && shutterSpeedMs != null) {
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                builder.set(CaptureRequest.SENSOR_SENSITIVITY, iso)
                builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, (shutterSpeedMs * 1_000_000).toLong())
            } else {
                builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            }
            updateRepeating()
        }
    }

    fun setWhiteBalance(mode: String) {
        previewRequestBuilder?.let { builder ->
            builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            updateRepeating()
        }
    }

    private fun updateRepeating() {
        try {
            val session = captureSession ?: return
            val builder = previewRequestBuilder ?: return
            session.setRepeatingRequest(builder.build(), null, backgroundHandler)
        } catch (_: Exception) {}
    }

    fun stop() {
        try {
            cameraOpenCloseLock.acquire()
            captureSession?.stopRepeating()
            captureSession?.close()
            captureSession = null

            cameraDevice?.close()
            cameraDevice = null
        } catch (_: Exception) {
        } finally {
            cameraOpenCloseLock.release()
        }
        stopBackgroundThread()
    }
}
