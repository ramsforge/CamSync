import Foundation
import VideoToolbox
import CoreMedia

class HardwareEncoder {
    private var compressionSession: VTCompressionSession?
    private var isEncoding = false
    private var sequenceNumber: UInt32 = 0
    private var startNanoTime: UInt64 = 0
    private let onPacketEncoded: (Data) -> Void

    private let magic: UInt32 = 0x43534E43 // 'CSNC'
    private let protocolVersion: UInt8 = 1
    private let headerSize = 20

    init(width: Int32, height: Int32, fps: Int32 = 30, onPacketEncoded: @escaping (Data) -> Void) {
        self.onPacketEncoded = onPacketEncoded

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        if status == noErr, let session = compressionSession {
            // Low-latency configuration
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 4_000_000))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTCompressionSessionPrepareToEncodeFrames(session)
            isEncoding = true
            startNanoTime = DispatchTime.now().uptimeNanoseconds
        } else {
            print("[HardwareEncoder] Failed to create VTCompressionSession: \(status)")
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard isEncoding, let session = compressionSession else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func stop() {
        isEncoding = false
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    fileprivate func handleEncodedSample(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Check for Keyframe safely without force casts
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        } else if sequenceNumber == 0 {
            isKeyframe = true
        }

        // If keyframe, emit SPS and PPS parameter sets first (Type 1: Config)
        if isKeyframe {
            var spsSize: Int = 0
            var spsCount: Int = 0
            var spsPointer: UnsafePointer<UInt8>?

            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPointer, spsSize > 0 {
                emitPacket(type: 1, payload: Data(bytes: sps, count: spsSize))
            }

            var ppsSize: Int = 0
            var ppsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let pps = ppsPointer, ppsSize > 0 {
                emitPacket(type: 1, payload: Data(bytes: pps, count: ppsSize))
            }
        }

        // Get video data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 4 else { return }

        var rawData = Data(count: totalLength)
        let copyStatus = rawData.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let baseAddress = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, byteLength: totalLength, destination: baseAddress)
        }
        guard copyStatus == noErr else { return }

        var bufferOffset = 0
        let avcHeaderLength = 4

        while bufferOffset + avcHeaderLength <= totalLength {
            var nalUnitLength: UInt32 = 0
            rawData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                memcpy(&nalUnitLength, base + bufferOffset, avcHeaderLength)
            }
            nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)

            let nalLen = Int(nalUnitLength)
            if nalLen <= 0 || bufferOffset + avcHeaderLength + nalLen > totalLength {
                break
            }

            let nalData = rawData.subdata(in: (bufferOffset + avcHeaderLength)..<(bufferOffset + avcHeaderLength + nalLen))
            // Type 2: Keyframe, Type 3: P-frame
            emitPacket(type: isKeyframe ? 2 : 3, payload: nalData)

            bufferOffset += avcHeaderLength + nalLen
        }
    }

    private func emitPacket(type: UInt8, payload: Data) {
        var header = Data(count: headerSize)
        let elapsedMs: UInt32
        if startNanoTime > 0 {
            let diffNano = DispatchTime.now().uptimeNanoseconds - startNanoTime
            elapsedMs = UInt32(diffNano / 1_000_000)
        } else {
            elapsedMs = 0
        }

        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: magic.bigEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: protocolVersion, toByteOffset: 4, as: UInt8.self)
            ptr.storeBytes(of: type, toByteOffset: 5, as: UInt8.self)
            ptr.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 6, as: UInt16.self)
            ptr.storeBytes(of: sequenceNumber.bigEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: elapsedMs.bigEndian, toByteOffset: 12, as: UInt32.self)
            ptr.storeBytes(of: UInt32(payload.count).bigEndian, toByteOffset: 16, as: UInt32.self)
        }
        sequenceNumber &+= 1

        var packet = header
        packet.append(payload)
        onPacketEncoded(packet)
    }
}

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<HardwareEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedSample(sampleBuffer: sampleBuffer)
}
