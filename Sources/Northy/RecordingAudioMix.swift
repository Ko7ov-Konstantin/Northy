import AVFoundation

/// SCK пишет звук системы и микрофон отдельными дорожками, а мессенджеры и браузеры играют только первую.
nonisolated enum RecordingAudioMix {
    private typealias Samples = AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>

    /// Звуковых дорожек больше одной — файл пересобирается на месте с одной общей; видео не перекодируется.
    static func mixDown(_ file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1 else { return }
        let video = try await asset.loadTracks(withMediaType: .video)
        var formats: [AudioStreamBasicDescription] = []
        for track in audio {
            formats += try await track.load(.formatDescriptions).compactMap(\.audioStreamBasicDescription)
        }
        guard video.count == 1, let widest = formats.max(by: { $0.mChannelsPerFrame < $1.mChannelsPerFrame }) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        // Больше двух каналов и 48 кГц AAC без явной раскладки не кодирует.
        let channels = min(Int(widest.mChannelsPerFrame), 2)
        let sampleRate = min(widest.mSampleRate, 48_000)

        let mixed = file.deletingLastPathComponent().appendingPathComponent("Northy-mix-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: mixed) }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: mixed, fileType: .mov)

        let picture = AVAssetReaderTrackOutput(track: video[0], outputSettings: nil)
        let pictureInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await video[0].load(.formatDescriptions).first)
        pictureInput.transform = try await video[0].load(.preferredTransform)
        let sound = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000 * channels,
        ])
        guard reader.canAdd(picture), reader.canAdd(sound), writer.canAdd(pictureInput), writer.canAdd(soundInput) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        // outputProvider и inputReceiver сами добавляют выход и вход; повторный add — исключение.
        let pictureSamples = reader.outputProvider(for: picture), pictureReceiver = writer.inputReceiver(for: pictureInput)
        let soundSamples = reader.outputProvider(for: sound), soundReceiver = writer.inputReceiver(for: soundInput)
        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        // Дорожки пишутся одновременно: файл чередует их, и вход ждёт, пока отставшая догонит.
        async let pictureCopied: Void = copy(pictureSamples, to: pictureReceiver)
        async let soundCopied: Void = copy(soundSamples, to: soundReceiver)
        _ = try await (pictureCopied, soundCopied)
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
        // Отмена — приложение завершается и уже унесло исходный файл на полку.
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(file, withItemAt: mixed)
    }

    private static func copy(_ samples: sending Samples, to receiver: sending AVAssetWriterInput.SampleBufferReceiver) async throws {
        // И при ошибке: иначе соседняя дорожка вечно ждёт, пока эта её догонит.
        defer { receiver.finish() }
        while let buffer = try await samples.next() {
            try await receiver.append(buffer)
        }
    }
}
