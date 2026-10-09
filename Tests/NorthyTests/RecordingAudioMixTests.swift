import AVFoundation
import Foundation
import Testing
@testable import Northy

/// Сведение звука записи: ролики собирает настоящий AVAssetWriter, экран и микрофон не нужны.
struct RecordingAudioMixTests {

    private enum Sound { case silence, tone }

    private static let sampleRate = 48_000
    private static let frameSize = CGSize(width: 320, height: 240)
    private static let rotation = CGAffineTransform(rotationAngle: .pi / 2)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NorthyTests-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ролик на 1 с: повёрнутое видео и по звуковой дорожке на каждый элемент `sounds` (каналов — 2, 1, 1…).
    private func makeMovie(in directory: URL, sounds: [Sound]) async throws -> URL {
        let url = directory.appendingPathComponent("Запись.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.frameSize.width,
            AVVideoHeightKey: Self.frameSize.height,
        ])
        video.transform = Self.rotation
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.frameSize.width,
            kCVPixelBufferHeightKey as String: Self.frameSize.height,
        ])
        writer.add(video)

        let audio = sounds.indices.map { index in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: index == 0 ? 2 : 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        }
        audio.forEach(writer.add)

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            try await waitUntilReady(video)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            #expect(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        video.markAsFinished()
        for (index, input) in audio.enumerated() {
            try await waitUntilReady(input)
            #expect(input.append(try pcmBuffer(sounds[index], channels: index == 0 ? 2 : 1)))
            input.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func pcmBuffer(_ sound: Sound, channels: Int) throws -> CMSampleBuffer {
        let frames = Self.sampleRate
        var samples = [Int16](repeating: 0, count: frames * channels)
        if sound == .tone {
            for frame in 0..<frames {
                let value = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(Self.sampleRate)) * 16_000)
                for channel in 0..<channels { samples[frame * channels + channel] = value }
            }
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: try #require(block), offsetIntoDestination: 0, dataLength: bytes)
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format), sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    /// Наибольший по модулю отсчёт единственной звуковой дорожки.
    private func loudestSample(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var loudest = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = try buffer.dataBuffer?.dataBytes() else { continue }
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) { loudest = max(loudest, abs(Int(sample))) }
            }
        }
        #expect(reader.status == .completed)
        return loudest
    }

    private func leftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    @Test func twoAudioTracksBecomeOne() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeMovie(in: directory, sounds: [.tone, .tone])
        let sourceDuration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 2)
        // Файл хранит поворот с округлением, поэтому сравниваем с тем, что прочиталось из исходника.
        let sourceTransform = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.preferredTransform)
        #expect(sourceTransform != .identity)

        try await RecordingAudioMix.mixDown(url)

        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        #expect(audio.count == 1)
        #expect(video.count == 1)
        #expect(abs(try await asset.load(.duration).seconds - sourceDuration) <= 0.1)
        let picture = try #require(video.first)
        #expect(try await picture.load(.naturalSize) == Self.frameSize)
        #expect(try await picture.load(.preferredTransform) == sourceTransform, "ориентация видео сохранена")
        let format = try #require(try await audio.first?.load(.formatDescriptions).first?.audioStreamBasicDescription)
        #expect(format.mFormatID == kAudioFormatMPEG4AAC)
        #expect(format.mChannelsPerFrame == 2, "каналов — как у самой широкой исходной дорожки")
        #expect(Int(format.mSampleRate) == Self.sampleRate)
        #expect(try leftovers(in: directory) == [url.lastPathComponent], "файл на том же месте, временных нет")
    }

    @Test(arguments: [[Sound.silence, .tone], [.tone, .silence]])
    private func bothSourcesAreAudible(sounds: [Sound]) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeMovie(in: directory, sounds: sounds)

        try await RecordingAudioMix.mixDown(url)

        #expect(try await loudestSample(in: url) > 1_000, "тон из любой дорожки слышен в сведённой")
    }

    @Test func silentTracksStaySilent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeMovie(in: directory, sounds: [.silence, .silence])

        try await RecordingAudioMix.mixDown(url)

        #expect(try await loudestSample(in: url) < 100, "проверка громкости отличает тишину от тона")
    }

    @Test(arguments: [[Sound.tone], []])
    private func fileWithoutSecondTrackIsUntouched(sounds: [Sound]) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeMovie(in: directory, sounds: sounds)
        let before = try Data(contentsOf: url)

        try await RecordingAudioMix.mixDown(url)

        #expect(try Data(contentsOf: url) == before)
        #expect(try leftovers(in: directory) == [url.lastPathComponent])
    }

    @Test func brokenFileIsLeftAsIs() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Запись.mov")
        let before = Data("это не видео".utf8)
        try before.write(to: url)

        try? await RecordingAudioMix.mixDown(url)

        #expect(try Data(contentsOf: url) == before)
        #expect(try leftovers(in: directory) == [url.lastPathComponent])
    }
}
