package com.camsync.mobile

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

class HardwareEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int = 60,
    private val bitrateBps: Int = 15_000_000, // 15 Mbps for 1080p60
    private val onPacketEncoded: (ByteArray) -> Unit
) {
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var isEncoding = false
    private var workerThread: Thread? = null

    private var sequenceNumber = 0
    private var startTimeMs = 0L

    companion object {
        private const val MAGIC = 0x43534E43 // 'CSNC'
        private const val PROTOCOL_VERSION = 1
        private const val HEADER_SIZE = 20

        private const val FRAME_TYPE_CONFIG = 1
        private const val FRAME_TYPE_KEYFRAME = 2
        private const val FRAME_TYPE_DELTA = 3
    }

    fun start(): Surface {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // Keyframe every 1 second
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            try {
                // Low-latency encoder configuration
                setInteger(MediaFormat.KEY_LATENCY, 0)
                setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority
            } catch (_: Exception) {}
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()

        mediaCodec = codec
        isEncoding = true
        startTimeMs = System.currentTimeMillis()
        sequenceNumber = 0

        workerThread = Thread { runDrainLoop() }.apply {
            priority = Thread.MAX_PRIORITY
            start()
        }

        return inputSurface!!
    }

    private fun runDrainLoop() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()

        while (isEncoding) {
            val outputBufferIndex = try {
                codec.dequeueOutputBuffer(bufferInfo, 10_000L) // 10ms timeout
            } catch (e: Exception) {
                break
            }

            if (outputBufferIndex >= 0) {
                val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                if (outputBuffer != null && bufferInfo.size > 0) {
                    outputBuffer.position(bufferInfo.offset)
                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                    val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                    val frameType = when {
                        isConfig -> FRAME_TYPE_CONFIG
                        isKeyFrame -> FRAME_TYPE_KEYFRAME
                        else -> FRAME_TYPE_DELTA
                    }

                    val payloadSize = bufferInfo.size
                    val totalSize = HEADER_SIZE + payloadSize
                    val packet = ByteArray(totalSize)
                    val bb = ByteBuffer.wrap(packet).order(ByteOrder.BIG_ENDIAN)

                    // 20-byte CamSync header
                    bb.putInt(MAGIC)
                    bb.put(PROTOCOL_VERSION.toByte())
                    bb.put(frameType.toByte())
                    bb.putShort(0.toShort()) // Reserved
                    bb.putInt(sequenceNumber++)
                    val elapsedMs = (System.currentTimeMillis() - startTimeMs).toInt()
                    bb.putInt(elapsedMs)
                    bb.putInt(payloadSize)

                    // Payload
                    outputBuffer.get(packet, HEADER_SIZE, payloadSize)

                    onPacketEncoded(packet)
                }
                codec.releaseOutputBuffer(outputBufferIndex, false)
            }
        }
    }

    fun stop() {
        isEncoding = false
        workerThread?.interrupt()
        workerThread?.join(1000)
        workerThread = null

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (_: Exception) {}
        mediaCodec = null

        try {
            inputSurface?.release()
        } catch (_: Exception) {}
        inputSurface = null
    }
}
