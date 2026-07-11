import Foundation
import AVFoundation
import CoreMedia

/// AVAssetWriter recording state machine for one camera session. Records from
/// the existing video-data output (+ the audio-data output) and NEVER
/// adds/removes an output on the running session (which is what causes the
/// FigCapture interruptions of the old AVCaptureMovieFileOutput approach).
///
/// All recording-state mutation + reads happen on `frameQueue`, so the sample
/// callbacks and start/stop never race. The running session is never touched.
///
/// vision-camera analogue: ios/Hybrid Objects/Recording/HybridVideoRecorder.swift
/// (v5 drives AVCaptureMovieFileOutput there; our writer-based timeline
/// handling — pause retiming, endSession at the last video frame — ports their
/// Recording/TrackTimeline.swift + Recording/HybridFrameRecorder.swift).
final class VideoRecorder {

    private let device: AVCaptureDevice
    private let session: AVCaptureSession
    private let sessionQueue: DispatchQueue
    private let frameQueue: DispatchQueue
    private let videoOutput: AVCaptureVideoDataOutput

    /// Whether the session graph has an audio-data output feeding us — set
    /// during session configuration; recordings then mux an AAC audio track.
    var hasAudioOutput = false
    /// Event hook: (CameraEventType index, message) — wired to the session's hub.
    var onEvent: ((Int64, String) -> Void)?

    // Writer state — touched on `frameQueue` (see class comment).
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var isWriting = false
    private var recordingPaused = false

    /// True while a recording is actively writing frames (read on `frameQueue`
    /// by FrameOutput to decide whether to spend GPU rendering the shader-filtered
    /// frame — the live preview is filtered on the Flutter layer, so the native
    /// filter is only needed for the recorded video).
    var isRecordingActive: Bool { isWriting && !recordingPaused }

    /// Pending stop continuation. Serialised by `continuationLock` so it is
    /// never leaked (set-but-never-resumed) or double-resumed (which is fatal)
    /// when a stop / finalise / teardown race.
    private var movieContinuation: CheckedContinuation<RecordingResult, Error>?
    private let continuationLock = NSLock()

    // Recording limits / timeline anchors captured at start.
    private var recordingMaxDurationMs: Int64 = 0
    private var recordingMaxFileSizeBytes: Int64 = 0
    private var recordingWidth: Int64 = 0
    private var recordingHeight: Int64 = 0
    private var recordingCodec: Int64 = 0
    private var recordingFileType: Int64 = 0
    private var recordingFinishedReason: Int64 = 0
    private var recordingStartPTS: CMTime = .invalid
    private var recordingSizeCheckTick = 0
    // Pause bookkeeping (vision-camera TrackTimeline port): while paused,
    // samples are dropped; on resume every subsequent sample is shifted back
    // by the accumulated pause duration, so the movie has NO frozen-frame gap
    // (an un-shifted timeline plays the pause as seconds of frozen video).
    // All three are touched on `frameQueue` only.
    private var pauseStartPTS: CMTime = .invalid
    private var totalPauseOffset: CMTime = .zero
    // Last (offset-adjusted) video PTS actually appended — finalisation ends
    // the writer session HERE so trailing audio can't lengthen the file past
    // the last video frame (vision-camera's endSession(atSourceTime:)).
    private var lastVideoPTS: CMTime = .invalid

    init(device: AVCaptureDevice,
         session: AVCaptureSession,
         sessionQueue: DispatchQueue,
         frameQueue: DispatchQueue,
         videoOutput: AVCaptureVideoDataOutput) {
        self.device = device
        self.session = session
        self.sessionQueue = sessionQueue
        self.frameQueue = frameQueue
        self.videoOutput = videoOutput
    }

    // MARK: - Start

    func start(to path: String, options: RecordingOptions) async throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard !isWriting, assetWriter == nil else { throw CameraError.captureInProgress }
        // Fail fast when the session can't deliver frames — otherwise the
        // writer never leaves `.unknown` and stop has nothing to finalise.
        // Checked ON the session queue so a just-dispatched startRunning
        // (open → start are async on that queue) counts as running.
        let running = sessionQueue.sync { session.isRunning }
        guard running else { throw CameraError.sessionNotRunning }

        let fileType: AVFileType = (options.fileType == 1) ? .mov : .mp4
        let url = URL(fileURLWithPath: path)
        // Validate the destination SYNCHRONOUSLY so a bad path throws here
        // (→ a typed RecorderException on the caller) instead of failing later
        // at startWriting() on the frame queue, where the only channel would be
        // a session-scoped error event. Matches Android's synchronous reject.
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CameraError.recordingFailed(
                "output directory does not exist: \(parent.path)")
        }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        // GPS geotag → QuickTime movie metadata.
        if options.hasLocation != 0 {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = Self.iso6709(lat: options.latitude,
                                      lon: options.longitude,
                                      alt: options.altitude) as NSString
            writer.metadata = [item]
        }

        // Video settings — ask the output for settings recommended FOR THE
        // TARGET CODEC (correct size + codec-appropriate compression keys).
        // Never override AVVideoCodecKey on another codec's recommendation:
        // on iOS 26 the plain `recommendedVideoSettingsForAssetWriter` returns
        // HEVC defaults whose compression properties (BaseLayerFrameRate…) are
        // invalid for H.264 — AVAssetWriterInput then throws an uncatchable
        // NSInvalidArgumentException and kills the app at start-recording.
        let wantedCodec: AVVideoCodecType = (options.codec == 1) ? .hevc : .h264
        // Fallback dimensions: buffers are delivered PORTRAIT (the session sets
        // connection.videoOrientation = .portrait), so the active format's
        // width/height are swapped.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var videoSettings = videoOutput.recommendedVideoSettings(
            forVideoCodecType: wantedCodec, assetWriterOutputFileType: fileType)
            ?? [
                AVVideoCodecKey: wantedCodec,
                AVVideoWidthKey: Int64(dims.height),
                AVVideoHeightKey: Int64(dims.width),
            ]
        videoSettings[AVVideoCodecKey] = wantedCodec
        if options.bitRate > 0 {
            var compression = (videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
            compression[AVVideoAverageBitRateKey] = options.bitRate
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let selectedWidth = Self.int64Setting(videoSettings[AVVideoWidthKey]) ?? Int64(dims.height)
        let selectedHeight = Self.int64Setting(videoSettings[AVVideoHeightKey]) ?? Int64(dims.width)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else { throw CameraError.configurationFailed }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if hasAudioOutput {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); aInput = ai }
        }

        // Publish on the frame queue so the sample callbacks see a consistent state.
        frameQueue.sync {
            self.assetWriter = writer
            self.videoWriterInput = vInput
            self.audioWriterInput = aInput
            self.recordingURL = url
            self.recordingStartTime = Date()
            self.recordingStartPTS = .invalid
            self.recordingMaxDurationMs = options.maxDurationMs
            self.recordingMaxFileSizeBytes = options.maxFileSizeBytes
            self.recordingWidth = selectedWidth
            self.recordingHeight = selectedHeight
            self.recordingCodec = options.codec == 1 ? 1 : 0
            self.recordingFileType = options.fileType == 1 ? 1 : 0
            self.recordingFinishedReason = 0
            self.recordingPaused = false
            self.pauseStartPTS = .invalid
            self.totalPauseOffset = .zero
            self.lastVideoPTS = .invalid
            self.isWriting = true
        }
        NSLog("NitroCamera record: start=%dms (fileType=%@ codec=%@)",
              Int((CFAbsoluteTimeGetCurrent() - t0) * 1000),
              fileType == .mov ? "mov" : "mp4",
              options.codec == 1 ? "hevc" : "h264")
    }

    /// ISO-6709 location string for QuickTime metadata, e.g. `+37.7749-122.4194+010.000/`.
    private static func iso6709(lat: Double, lon: Double, alt: Double) -> String {
        String(format: "%+09.5f%+010.5f%+.3f/", lat, lon, alt)
    }

    private static func int64Setting(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    // MARK: - Sample appends (on `frameQueue`, called by FrameOutput)

    /// Folds a completed pause into the running timestamp offset. Called with
    /// the first sample PTS delivered after a resume (video and audio share
    /// the capture clock, so whichever arrives first settles the gap). On
    /// `frameQueue`.
    private func settlePauseOffset(rawPTS: CMTime) {
        guard pauseStartPTS.isValid else { return }
        totalPauseOffset = CMTimeAdd(totalPauseOffset, CMTimeSubtract(rawPTS, pauseStartPTS))
        pauseStartPTS = .invalid
        NSLog("NitroCamera record: resumed — total pause offset now %.2fs",
              CMTimeGetSeconds(totalPauseOffset))
    }

    /// Applies the accumulated pause offset to [sampleBuffer] (vision-camera's
    /// `copyWithTimestampOffset(pauseOffset.inverted())`). Returns the original
    /// buffer when there is no offset or the retime fails (a frozen gap beats
    /// dropping media).
    private func retimedForPause(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard totalPauseOffset != .zero else { return sampleBuffer }
        return (try? sampleBuffer.copyWithTimestampOffset(
            CMTimeMultiply(totalPauseOffset, multiplier: -1))) ?? sampleBuffer
    }

    /// Appends a video frame to the writer (on `frameQueue`). Anchors the writer's
    /// session on the first frame so the timeline starts at t=0.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, let writer = assetWriter, let input = videoWriterInput else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordingPaused {
            // First dropped sample marks the pause start in the PTS domain.
            if !pauseStartPTS.isValid { pauseStartPTS = rawPTS }
            return
        }
        settlePauseOffset(rawPTS: rawPTS)
        let buffer = retimedForPause(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer.status == .unknown {
            let t0 = CFAbsoluteTimeGetCurrent()
            if writer.startWriting() {
                writer.startSession(atSourceTime: pts)
                recordingStartPTS = pts
                NSLog("NitroCamera record: writer started on first frame in %dms",
                      Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))
            } else {
                // Failed to start (bad settings/path/disk) — surface it now;
                // otherwise every append silently no-ops and stop() has
                // nothing to finalise.
                NSLog("NitroCamera record: startWriting FAILED: %@",
                      writer.error?.localizedDescription ?? "unknown")
                isWriting = false
                onEvent?(2 /* error */, writer.error?.localizedDescription ?? "recording failed to start")
                return
            }
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            if input.append(buffer) {
                lastVideoPTS = pts
            } else {
                NSLog("NitroCamera record: video append FAILED at %.2fs (writer status=%d)",
                      CMTimeGetSeconds(pts), writer.status.rawValue)
            }
        }
        // A writer that flipped to .failed mid-recording never recovers — every
        // further append silently no-ops and the failure would only surface at
        // stop(). Surface it NOW (vision-camera FrameRecorder.append pattern).
        if writer.status == .failed {
            failActiveRecording(writer)
            return
        }

        // Auto-stop on the configured limits (vision-camera's maxDuration/maxFileSize).
        // Uses the pause-adjusted PTS, so paused time doesn't count against the limit.
        if recordingMaxDurationMs > 0, recordingStartPTS.isValid {
            let elapsedMs = Int64(CMTimeGetSeconds(pts - recordingStartPTS) * 1000)
            if elapsedMs >= recordingMaxDurationMs {
                recordingFinishedReason = 1
                autoStopRecording()
                return
            }
        }
        if recordingMaxFileSizeBytes > 0 {
            recordingSizeCheckTick += 1
            if recordingSizeCheckTick % 15 == 0, let url = recordingURL {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
                if size >= recordingMaxFileSizeBytes {
                    recordingFinishedReason = 2
                    autoStopRecording()
                }
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, let writer = assetWriter else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordingPaused {
            if !pauseStartPTS.isValid { pauseStartPTS = rawPTS }
            return
        }
        settlePauseOffset(rawPTS: rawPTS)
        guard writer.status == .writing,
              let input = audioWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(retimedForPause(sampleBuffer))
    }

    // MARK: - Failure / limits (on `frameQueue`)

    /// Tears down a writer that failed MID-recording (on `frameQueue`) and
    /// emits an error event — there is no pending stop continuation in this
    /// path (stop takes `isWriting` first), so the event is the only channel.
    private func failActiveRecording(_ writer: AVAssetWriter) {
        guard isWriting else { return }
        isWriting = false
        let message = writer.error?.localizedDescription ?? "recording failed while writing"
        NSLog("NitroCamera record: writer FAILED mid-recording: %@", message)
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        recordingURL = nil
        onEvent?(2 /* error */, message)
    }

    /// Finalises the recording on a duration/size limit (on `frameQueue`) and
    /// emits a `stopped` event carrying the file path (there's no pending
    /// stop continuation in this path).
    private func autoStopRecording() {
        guard isWriting, let writer = assetWriter else { return }
        isWriting = false
        let url = recordingURL
        // Same status gate as stop(): finalising a writer that isn't
        // `.writing` raises an uncatchable NSException.
        guard writer.status == .writing else {
            assetWriter = nil
            videoWriterInput = nil
            audioWriterInput = nil
            recordingURL = nil
            onEvent?(2 /* error */, writer.error?.localizedDescription ?? "recording failed")
            return
        }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        // Bound the timeline at the last video frame (see stop()).
        if lastVideoPTS.isValid, recordingStartPTS.isValid,
           CMTimeCompare(lastVideoPTS, recordingStartPTS) > 0 {
            writer.endSession(atSourceTime: lastVideoPTS)
        }
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.frameQueue.async {
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.recordingURL = nil
            }
            if writer.status == .completed, let url = url {
                self.onEvent?(1 /* stopped */, url.path)
            } else {
                self.onEvent?(2 /* error */, writer.error?.localizedDescription ?? "recording failed")
            }
        }
    }

    // MARK: - Stop / pause / cancel

    func stop() async throws -> RecordingResult {
        let stopStart = CFAbsoluteTimeGetCurrent()
        return try await withCheckedThrowingContinuation { continuation in
            frameQueue.async {
                self.continuationLock.lock()
                let stopping = self.movieContinuation != nil
                guard self.isWriting, let writer = self.assetWriter, !stopping else {
                    self.continuationLock.unlock()
                    // Nothing recording / a stop already in flight → fail fast
                    // instead of leaking the continuation.
                    continuation.resume(throwing: CameraError.captureFailed)
                    return
                }
                self.movieContinuation = continuation
                self.continuationLock.unlock()

                self.isWriting = false
                let start = self.recordingStartTime
                let url = self.recordingURL

                // `markAsFinished`/`finishWriting` raise uncatchable
                // NSExceptions unless the writer is actually `.writing` —
                // status must gate the finalise path or an instant stop
                // (no frame arrived yet) / a failed writer kills the app.
                guard writer.status == .writing else {
                    let error = writer.error
                    NSLog("NitroCamera record: stop with writer status=%d (%@) — nothing to finalise",
                          writer.status.rawValue,
                          error?.localizedDescription ?? "no frames were appended")
                    self.assetWriter = nil
                    self.videoWriterInput = nil
                    self.audioWriterInput = nil
                    self.recordingURL = nil
                    if let url = url { try? FileManager.default.removeItem(at: url) }
                    self.takeMovieContinuation()?
                        .resume(throwing: error ?? CameraError.captureFailed)
                    return
                }

                self.videoWriterInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
                // End the timeline at the LAST VIDEO frame (vision-camera's
                // endSession(atSourceTime:)): trailing audio samples otherwise
                // extend the movie past the final frame as frozen video.
                if self.lastVideoPTS.isValid, self.recordingStartPTS.isValid,
                   CMTimeCompare(self.lastVideoPTS, self.recordingStartPTS) > 0 {
                    writer.endSession(atSourceTime: self.lastVideoPTS)
                }
                let startPTS = self.recordingStartPTS
                let endPTS = self.lastVideoPTS
                let resultWidth = self.recordingWidth
                let resultHeight = self.recordingHeight
                let resultCodec = self.recordingCodec
                let resultFileType = self.recordingFileType
                let resultReason = self.recordingFinishedReason
                // Watchdog: `finishWriting`'s completion is the ONLY path that
                // resumes the continuation — if the writer wedges, fail the
                // await instead of hanging Dart forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self = self, let cont = self.takeMovieContinuation() else { return }
                    NSLog("NitroCamera record: stop WATCHDOG — finishWriting silent for 10s (status=%d)",
                          writer.status.rawValue)
                    cont.resume(throwing: CameraError.captureTimedOut)
                }
                writer.finishWriting {
                    let cont = self.takeMovieContinuation()
                    self.frameQueue.async {
                        self.assetWriter = nil
                        self.videoWriterInput = nil
                        self.audioWriterInput = nil
                        self.recordingURL = nil
                    }
                    guard let cont = cont else { return }
                    if writer.status == .completed, let url = url {
                        // Media duration from the pause-adjusted PTS span (the
                        // wall clock would count paused time); wall-clock
                        // fallback when no frame was ever appended.
                        let duration: Int64
                        if startPTS.isValid, endPTS.isValid, CMTimeCompare(endPTS, startPTS) > 0 {
                            duration = Int64(CMTimeGetSeconds(CMTimeSubtract(endPTS, startPTS)) * 1000)
                        } else {
                            duration = Int64((Date().timeIntervalSince(start ?? Date())) * 1000)
                        }
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        NSLog("NitroCamera record: stop=%dms duration=%lldms size=%lld",
                              Int((CFAbsoluteTimeGetCurrent() - stopStart) * 1000), duration, size)
                        cont.resume(returning: RecordingResult(
                            path: url.path,
                            durationMs: duration,
                            fileSize: size,
                            width: resultWidth,
                            height: resultHeight,
                            codec: resultCodec,
                            fileType: resultFileType,
                            finishedReason: resultReason))
                    } else {
                        NSLog("NitroCamera record: stop FAILED status=%d error=%@",
                              writer.status.rawValue,
                              writer.error?.localizedDescription ?? "unknown")
                        cont.resume(throwing: writer.error ?? CameraError.captureFailed)
                    }
                }
            }
        }
    }

    // Dispatched to `frameQueue` — the flag and its pause-PTS bookkeeping are
    // read by the sample callbacks on that queue (mutating them from the
    // caller's thread was a data race).
    func pause()  { frameQueue.async { self.recordingPaused = true } }
    func resume() { frameQueue.async { self.recordingPaused = false } }

    func cancel() async throws {
        takeMovieContinuation()?.resume(throwing: CameraError.captureFailed)
        var url: URL?
        // Read + clear the recording state on `frameQueue` (it owns that state).
        frameQueue.sync {
            url = self.recordingURL
            self.isWriting = false
            if let w = self.assetWriter, w.status == .writing { w.cancelWriting() }
            self.assetWriter = nil
            self.videoWriterInput = nil
            self.audioWriterInput = nil
            self.recordingURL = nil
        }
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }

    /// Aborts any in-flight recording so the writer doesn't outlive the
    /// session, and fails a pending stop continuation. Called from
    /// CameraSession.close() — ON `frameQueue`: the sample callbacks read this
    /// state there, and one may still be mid-append even after the delegate
    /// detach that precedes this call.
    func interrupt() {
        frameQueue.sync {
            self.isWriting = false
            if let w = self.assetWriter, w.status == .writing { w.cancelWriting() }
            self.assetWriter = nil
            self.videoWriterInput = nil
            self.audioWriterInput = nil
        }
        takeMovieContinuation()?.resume(throwing: CameraError.captureFailed)
    }

    private func takeMovieContinuation() -> CheckedContinuation<RecordingResult, Error>? {
        continuationLock.lock(); defer { continuationLock.unlock() }
        let c = movieContinuation; movieContinuation = nil; return c
    }
}
