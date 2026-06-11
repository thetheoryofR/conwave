import AVFoundation
import Foundation

/// Controls the device camera and microphone, drives recording to disk.
///
/// Typical lifecycle:
///   1. `let session = CaptureSession()`
///   2. `await session.prepare()` — requests permissions, configures AVCaptureSession
///   3. Embed `session.previewLayer` in a UIView
///   4. `session.startRecording()` / `await session.stopRecording()`
///   5. Observe `session.lastClip` for the finished ClipMetadata
///   6. `session.teardown()` when the view disappears
///
/// All published properties are @MainActor. The AVCapture delegate callbacks run on
/// dedicated serial queues; writer access is protected with `writerLock`.
@MainActor
public final class CaptureSession: NSObject, ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRecording         = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var captureError: CaptureError?
    @Published public private(set) var lastClip: ClipMetadata?
    @Published public private(set) var isPrepared          = false

    // MARK: - Preview layer

    /// Attach this to a UIView layer in a UIViewRepresentable.
    public let previewLayer: AVCaptureVideoPreviewLayer

    // MARK: - Private

    private let avSession = AVCaptureSession()
    private var durationTimer: Timer?
    private var recordingStartDate: Date?

    // Shared across CaptureSession (main actor) and AVCapture delegate queues — lock-protected.
    private let writerLock                = NSLock()
    private nonisolated(unsafe) var activeWriter: VideoWriter?
    private nonisolated(unsafe) var writerStarted = false

    private let videoQueue = DispatchQueue(label: "com.conwave.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.conwave.capture.audio", qos: .userInitiated)

    // MARK: - Init

    public override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: avSession)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    // MARK: - Setup

    /// Request permissions and configure the AVCaptureSession.
    /// Must be called before `startRecording()`.
    public func prepare() async {
        let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        let audioGranted = await AVCaptureDevice.requestAccess(for: .audio)

        guard videoGranted && audioGranted else {
            captureError = .permissionDenied
            return
        }

        do {
            try configureSession()
            isPrepared = true
        } catch let e as CaptureError {
            captureError = e
        } catch {
            captureError = .sessionConfiguration(error.localizedDescription)
        }
    }

    private func configureSession() throws {
        avSession.beginConfiguration()
        avSession.sessionPreset = .hd1920x1080

        // Video input (rear wide-angle camera)
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: .back),
              let videoInput  = try? AVCaptureDeviceInput(device: videoDevice),
              avSession.canAddInput(videoInput) else {
            avSession.commitConfiguration()
            throw CaptureError.noCameraAvailable
        }
        avSession.addInput(videoInput)

        // Audio input (built-in microphone)
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput  = try? AVCaptureDeviceInput(device: audioDevice),
              avSession.canAddInput(audioInput) else {
            avSession.commitConfiguration()
            throw CaptureError.noMicrophoneAvailable
        }
        avSession.addInput(audioInput)

        // Video output → sample buffer delegate
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard avSession.canAddOutput(videoOutput) else {
            avSession.commitConfiguration()
            throw CaptureError.sessionConfiguration("Cannot add video output")
        }
        avSession.addOutput(videoOutput)

        // Portrait orientation (90° rotation)
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        }

        // Audio output → sample buffer delegate
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard avSession.canAddOutput(audioOutput) else {
            avSession.commitConfiguration()
            throw CaptureError.sessionConfiguration("Cannot add audio output")
        }
        avSession.addOutput(audioOutput)

        avSession.commitConfiguration()

        // Start running on a background thread so we don't block the main actor
        Task.detached(priority: .userInitiated) { [avSession] in
            avSession.startRunning()
        }
    }

    // MARK: - Recording control

    public func startRecording() {
        guard isPrepared, !isRecording else { return }
        captureError = nil

        do {
            let writer = try VideoWriter()
            writer.start()
            writerLock.withLock {
                activeWriter  = writer
                writerStarted = false
            }
        } catch {
            captureError = .writerFailed(error.localizedDescription)
            return
        }

        isRecording         = true
        recordingStartDate  = .now
        recordingDuration   = 0

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date.now.timeIntervalSince(start)
            }
        }
    }

    public func stopRecording() async {
        guard isRecording else {
            captureError = .noActiveRecording
            return
        }

        isRecording = false
        durationTimer?.invalidate()
        durationTimer = nil
        let duration = recordingDuration
        let startDate = recordingStartDate ?? .now

        let writer = writerLock.withLock { () -> VideoWriter? in
            let w = activeWriter
            activeWriter  = nil
            writerStarted = false
            return w
        }

        guard let writer else { return }

        do {
            let url  = try await writer.finish()
            var clip = ClipMetadata(originalURL: url, duration: duration, recordedAt: startDate)
            lastClip = clip

            // Transcode preview without blocking the main actor
            let clipId = clip.id
            Task.detached(priority: .utility) { [weak self] in
                do {
                    let previewURL = try await VideoTranscoder.transcode(inputURL: url)
                    await MainActor.run { [weak self] in
                        guard let self, self.lastClip?.id == clipId else { return }
                        self.lastClip?.previewURL = previewURL
                    }
                } catch {
                    print("[CaptureKit] Preview transcode failed: \(error.localizedDescription)")
                }
            }
        } catch {
            captureError = .writerFailed(error.localizedDescription)
        }
    }

    // MARK: - Teardown

    public func teardown() {
        Task.detached(priority: .utility) { [avSession] in
            avSession.stopRunning()
        }
    }
}

// MARK: - AVCapture sample buffer delegates

extension CaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        writerLock.withLock {
            guard let writer = activeWriter else { return }
            if output is AVCaptureVideoDataOutput {
                writer.appendVideo(sampleBuffer)
            } else {
                writer.appendAudio(sampleBuffer)
            }
        }
    }
}
