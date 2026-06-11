import AVFoundation
import XCTest
@testable import CaptureKit

/// Unit tests that run without a physical camera or microphone.
/// AVCaptureSession is not available on simulator, so capture session
/// tests are skipped there. Transcode and metadata tests use synthetic
/// video files built in-memory with AVAssetWriter.
final class CaptureKitTests: XCTestCase {

    // MARK: - ClipMetadata

    func testClipMetadataEquality() {
        let url  = URL(fileURLWithPath: "/tmp/test.mov")
        let date = Date(timeIntervalSince1970: 1_000_000)
        let a    = ClipMetadata(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                originalURL: url, duration: 30, recordedAt: date)
        let b    = ClipMetadata(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                originalURL: url, duration: 30, recordedAt: date)
        XCTAssertEqual(a, b)
    }

    func testClipMetadataMutablePreviewURL() {
        let url = URL(fileURLWithPath: "/tmp/test.mov")
        var clip = ClipMetadata(originalURL: url, duration: 10)
        XCTAssertNil(clip.previewURL)
        clip.previewURL = URL(fileURLWithPath: "/tmp/preview.mp4")
        XCTAssertNotNil(clip.previewURL)
    }

    // MARK: - CaptureError

    func testCaptureErrorDescriptions() {
        let errors: [CaptureError] = [
            .permissionDenied, .noCameraAvailable, .noMicrophoneAvailable,
            .sessionConfiguration("detail"), .writerFailed("oops"),
            .transcodeFailed("bad"), .noActiveRecording,
        ]
        for err in errors {
            XCTAssertNotNil(err.localizedDescription, "\(err) should have a description")
            XCTAssertFalse(err.localizedDescription!.isEmpty)
        }
    }

    func testCaptureErrorIsIdentifiable() {
        let err = CaptureError.writerFailed("test")
        XCTAssertFalse(err.id.isEmpty)
    }

    // MARK: - VideoTranscoder: error handling

    func testTranscodeNonExistentURLThrows() async {
        let badURL = URL(fileURLWithPath: "/nonexistent/video.mov")
        do {
            _ = try await VideoTranscoder.transcode(inputURL: badURL)
            XCTFail("Should throw for non-existent input")
        } catch {
            // Expected: AVFoundation will report the missing file or zero duration.
            XCTAssertNotNil(error)
        }
    }

    // MARK: - VideoTranscoder: synthetic video round-trip

    /// Builds a 2-second silent 640×480 video in-memory, transcodes it to 720p,
    /// and verifies the output file exists and has a non-zero duration.
    func testTranscodeSyntheticVideo() async throws {
        guard ProcessInfo.processInfo.environment["SKIP_TRANSCODE_TEST"] == nil else {
            throw XCTSkip("SKIP_TRANSCODE_TEST set")
        }

        let inputURL = try makeSyntheticVideo(duration: 2.0)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outputURL = try await VideoTranscoder.transcode(inputURL: inputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "Transcoded file should exist at \(outputURL.path)")

        let asset    = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1.0,
                             "Transcoded video should be at least 1 second")
    }

    func testExtractAudioFromSyntheticVideo() async throws {
        guard ProcessInfo.processInfo.environment["SKIP_TRANSCODE_TEST"] == nil else {
            throw XCTSkip("SKIP_TRANSCODE_TEST set")
        }

        let inputURL = try makeSyntheticVideo(duration: 2.0)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let audioURL = try await VideoTranscoder.extractAudio(inputURL: inputURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty, "Extracted audio file should have at least one audio track")
    }

    // MARK: - CaptureSession: state machine (no camera needed)

    @MainActor
    func testCaptureSessionInitialState() {
        let session = CaptureSession()
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isPrepared)
        XCTAssertNil(session.captureError)
        XCTAssertNil(session.lastClip)
        XCTAssertEqual(session.recordingDuration, 0, accuracy: 0.01)
    }

    @MainActor
    func testStartRecordingWithoutPrepareDoesNotRecord() {
        let session = CaptureSession()
        session.startRecording()           // isPrepared == false → no-op
        XCTAssertFalse(session.isRecording)
    }

    @MainActor
    func testStopRecordingWithoutStartSetsError() async {
        let session = CaptureSession()
        await session.stopRecording()
        XCTAssertEqual(session.captureError, .noActiveRecording)
    }
}

// MARK: - Synthetic Video Helper

private func makeSyntheticVideo(duration: Double) throws -> URL {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

    // Video track: 640×480 BGRA (simple, no GPU required)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey:  AVVideoCodecType.h264,
        AVVideoWidthKey:  640,
        AVVideoHeightKey: 480,
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)

    // Audio track: AAC stereo (silent)
    let audioSettings: [String: Any] = [
        AVFormatIDKey:         kAudioFormatMPEG4AAC,
        AVSampleRateKey:       44_100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey:   64_000,
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = false
    writer.add(audioInput)

    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "CaptureKitTests", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
    }

    writer.startSession(atSourceTime: .zero)

    // Append pixel buffers (grey frames at 30 fps)
    let fps:       Double = 30
    let frameCount = Int(duration * fps)
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

    for i in 0..<frameCount {
        while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
        if let buf = makeGreyPixelBuffer(width: 640, height: 480) {
            var timed = buf
            // Wrap in CMSampleBuffer
            if let sb = makeSampleBuffer(pixelBuffer: buf, pts: pts, duration: frameDuration) {
                _ = timed  // suppress unused warning
                videoInput.append(sb)
            }
        }
    }

    // Append silent audio frames
    let silentSamples = Int(duration * 44_100)
    let silentBlockSize = 4096
    var offset = 0
    while offset < silentSamples {
        while !audioInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        let count = min(silentBlockSize, silentSamples - offset)
        if let sb = makeSilentAudioBuffer(sampleCount: count,
                                          startSample: offset,
                                          sampleRate: 44_100) {
            audioInput.append(sb)
        }
        offset += count
    }

    videoInput.markAsFinished()
    audioInput.markAsFinished()

    return try await withCheckedThrowingContinuation { cont in
        writer.finishWriting {
            if writer.status == .completed {
                cont.resume(returning: outputURL)
            } else {
                cont.resume(throwing: writer.error
                    ?? NSError(domain: "CaptureKitTests", code: -2,
                               userInfo: [NSLocalizedDescriptionKey: "Write failed"]))
            }
        }
    }
}

private func makeGreyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height,
                        kCVPixelFormatType_32BGRA, nil, &pb)
    guard let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    if let base = CVPixelBufferGetBaseAddress(buf) {
        memset(base, 0x80, height * CVPixelBufferGetBytesPerRow(buf))
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

private func makeSampleBuffer(pixelBuffer: CVPixelBuffer,
                               pts: CMTime,
                               duration: CMTime) -> CMSampleBuffer? {
    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
    guard let fmt = formatDesc else { return nil }

    var info = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: nil,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: fmt,
        sampleTiming: &info,
        sampleBufferOut: &sb)
    return sb
}

private func makeSilentAudioBuffer(sampleCount: Int,
                                    startSample: Int,
                                    sampleRate: Double) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate:       sampleRate,
        mFormatID:         kAudioFormatLinearPCM,
        mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket:   8,
        mFramesPerPacket:  1,
        mBytesPerFrame:    8,
        mChannelsPerFrame: 2,
        mBitsPerChannel:   32,
        mReserved:         0
    )

    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                   layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil,
                                   extensions: nil, formatDescriptionOut: &fmt)
    guard let audioFmt = fmt else { return nil }

    let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate))
    var timing = CMSampleTimingInfo(
        duration:               CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp:  pts,
        decodeTimeStamp:        .invalid
    )

    var sb: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator:             nil,
        dataBuffer:            nil,
        dataReady:             false,
        makeDataReadyCallback: nil,
        refcon:                nil,
        formatDescription:     audioFmt,
        sampleCount:           sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray:     &timing,
        sampleSizeEntryCount:  0,
        sampleSizeArray:       nil,
        sampleBufferOut:       &sb
    )

    guard let buffer = sb else { return nil }

    // Attach silent PCM block
    let dataSize = sampleCount * 8   // 2 ch × 4 bytes float
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator:     nil,
        memoryBlock:   nil,
        blockLength:   dataSize,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData:  0,
        dataLength:    dataSize,
        flags:         kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
    )
    guard let blk = block else { return nil }
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: blk, offsetIntoDestination: 0, dataLength: dataSize)
    CMSampleBufferSetDataBuffer(buffer, newValue: blk)
    return buffer
}
