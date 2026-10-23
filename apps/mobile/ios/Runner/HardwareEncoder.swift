import Foundation
import VideoToolbox
import CoreMedia

class HardwareEncoder {
    private var compressionSession: VTCompressionSession?
    private var isEncoding = false
    private var sequenceNumber: UInt32 = 0
    private var startTimeMs: UInt32 = 0
    private let onPacketEncoded: (Data) -> Void

    private let magic: UInt32 = 0x43534E43 // 'CSNC'
    private let protocolVersion: UInt8 = 1
    private let headerSize = 20

    init(width: Int32, height: Int32, fps: Int32 = 60, onPacketEncoded: @escaping (Data) -> Void) {
        self.onPacketEncoded = onPacketEncoded

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        if status == noErr, let session = compressionSession {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 15_000_000))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTCompressionSessionPrepareToEncodeFrames(session)
            isEncoding = true
            startTimeMs = UInt32(Date().timeIntervalSince1970 * 1000)
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
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    fileprivate func handleEncodedSample(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Check for Keyframe
        let isKeyframe = !CFDictionaryContainsKey(
            unsafeBitCast(CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false), 0), to: CFDictionary.self),
            unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)
        )

        // If keyframe, send SPS and PPS config first
        if isKeyframe {
            var spsSize: Int = 0
            var spsCount: Int = 0
            var spsPointer: UnsafePointer<UInt8>?

            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPointer {
                emitPacket(type: 1, payload: Data(bytes: sps, count: spsSize))
            }

            var ppsSize: Int = 0
            var ppsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let pps = ppsPointer {
                emitPacket(type: 1, payload: Data(bytes: pps, count: ppsSize))
            }
        }

        // Send NAL units in data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
           let dataPtr = dataPointer {
            var bufferOffset = 0
            let avcHeaderLength = 4

            while bufferOffset < totalLength - avcHeaderLength {
                var nalUnitLength: UInt32 = 0
                memcpy(&nalUnitLength, dataPtr + bufferOffset, avcHeaderLength)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)

                let nalData = Data(bytes: dataPtr + bufferOffset + avcHeaderLength, count: Int(nalUnitLength))
                emitPacket(type: isKeyframe ? 2 : 3, payload: nalData)

                bufferOffset += avcHeaderLength + Int(nalUnitLength)
            }
        }
    }

    private func emitPacket(type: UInt8, payload: Data) {
        var header = Data(count: headerSize)
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: magic.bigEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: protocolVersion, toByteOffset: 4, as: UInt8.self)
            ptr.storeBytes(of: type, toByteOffset: 5, as: UInt8.self)
            ptr.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 6, as: UInt16.self)
            ptr.storeBytes(of: sequenceNumber.bigEndian, toByteOffset: 8, as: UInt32.self)
            let elapsed = UInt32(Date().timeIntervalSince1970 * 1000) - startTimeMs
            ptr.storeBytes(of: elapsed.bigEndian, toByteOffset: 12, as: UInt32.self)
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
