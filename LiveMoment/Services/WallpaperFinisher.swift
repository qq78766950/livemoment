import AVFoundation
import CoreMedia
import Foundation

/// 壁纸模式的后处理：把导出的 MOV 原样重封装一遍，做三件 `AVAssetExportSession` 做不到的事。
///
/// 1. **把视频轨的媒体时间基钉到 600**。ffmpeg 那条经典命令里的
///    `-video_track_timescale 600` 就是这件事。时间基太小的话，
///    0.9166666… 秒没法用整数刻度表示，时长会被取整成别的值，
///    而 iOS 的壁纸判定是**精确**比对，差一个 tick 就不认。
/// 2. **写入 `com.apple.quicktime.still-image-time` 时间元数据轨**，标出哪一帧是封面帧。
///    这是一条**时间**元数据轨（每个时刻一个值），而 `AVAssetExportSession`
///    只能写静态元数据，写不了它——所以必须自己用 `AVAssetWriter` 封一遍。
/// 3. 顺带把配对标识等静态元数据搬到新文件上。重封装**不会**自动继承
///    `moov/meta`，不显式再写一遍的话，配对标识就丢了，那样连普通实况照片都不是了。
///
/// 采样数据是原样搬运的（passthrough），不解码、不重编，所以不损画质、也不慢。
///
/// 有一件事这里**不伪造**：真实拍摄的实况照片还带一条
/// `com.apple.quicktime.live-photo-info` 时间元数据轨，里面是每帧一段的
/// 陀螺仪/加速度读数。那是拍摄时的真实传感器数据，格式也没公开，
/// 编不出来。缺了它 iOS 有可能仍然拒绝把这张图当壁纸——这一点只能上真机才知道。
enum WallpaperFinisher {

    /// 重封装的目标时间基。550 个 tick 正好是 0.9166666… 秒。
    static let targetTimeScale: CMTimeScale = 600

    struct Output {
        let url: URL
        /// 落盘后的视频轨媒体时间基。
        let timeScale: Int32
        /// 时间基是否达成了 600 或它的整数倍。
        let timeScaleOK: Bool
        /// 是否确认写入了 still-image-time 轨。
        let stillTimeWritten: Bool
        /// 给用户看的一句说明，正常为 nil。
        let note: String?
    }

    /// 重封装。失败时抛错，由调用方保留原来的导出结果。
    static func apply(
        sourceURL: URL,
        outputURL: URL,
        stillTime: Double,
        metadata: [AVMetadataItem]
    ) async throws -> Output {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError.exportFailed("重封装时找不到视频轨")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let transform = try await videoTrack.load(.preferredTransform)
        let formatHint = try await videoTrack.load(.formatDescriptions).first

        let manager = FileManager.default
        try? manager.removeItem(at: outputURL)

        // MARK: 写入端
        //
        // 顺序上先建写入端、再建读取端：`AVAssetReader` 没有「移除输出轨」的 API
        // （只有 canAdd / add），一旦加进去就撤不回来。所以必须先问清楚写入端
        // 收不收这条音轨，收不下就干脆不往读取端加，省得读出来没地方放。

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoInput.expectsMediaDataInRealTime = false
        // 旋转信息要带到新文件上，否则竖屏素材会被压成横向
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw LivePhotoError.exportFailed("无法写入视频轨")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        // still-image-time 轨。构造不出格式描述就跳过，其余部分照做。
        var metadataInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputMetadataAdaptor?
        if let description = stillImageTimeFormatDescription() {
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                metadataInput = input
                adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
            }
        }

        // 重封装不会继承 moov/meta，配对标识与壁纸字段必须重新写一遍
        writer.metadata = metadata

        // MARK: 读取端（原样取压缩样本）

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw LivePhotoError.exportFailed("无法读取导出的视频轨")
        }
        reader.add(videoOutput)

        // 只有写入端收下了音轨，才把对应的读取轨接上
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, audioInput != nil {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard writer.startWriting() else {
            throw LivePhotoError.exportFailed(writer.error?.localizedDescription ?? "重封装无法开始")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw LivePhotoError.exportFailed(reader.error?.localizedDescription ?? "无法读取导出的视频")
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: 搬运样本
        //
        // 视频和音频必须**同时**在搬。写入器要按时间交织两条轨的样本，
        // 只喂一条的话它的缓冲很快写满，`isReadyForMoreMediaData` 变成 false，
        // 那条轨就停在半路等对方——而对方还没开始，直接死等。
        let pumpQueue = DispatchQueue(label: "com.example.livemoment.wallpaper")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = PendingCounter(audioInput != nil && audioOutput != nil ? 2 : 1)
            let finish: () -> Void = {
                if pending.decrementReachedZero() { continuation.resume() }
            }
            pump(output: videoOutput, input: videoInput, queue: pumpQueue, retime: true, completion: finish)
            if let audioInput, let audioOutput {
                pump(output: audioOutput, input: audioInput, queue: pumpQueue, retime: false, completion: finish)
            }
        }

        // MARK: 写入封面帧标记
        //
        // 必须放在所有视频/音频样本**搬完之后**。封面帧标记的时间戳落在片段靠后的位置
        // （壁纸模式固定在最后一帧附近），先写它再写从 0 开始的视频样本，时间轴就倒退了，
        // 写入器会直接判为乱序而失败。放到最后写，时间戳天然是递增的。
        var stillTimeWritten = false
        if let adaptor, let metadataInput {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
            item.keySpace = .quickTimeMetadata
            item.value = NSNumber(value: Int8(0))
            item.dataType = "com.apple.metadata.datatype.int8"

            let start = CMTime(seconds: max(0, stillTime), preferredTimescale: targetTimeScale)
            let group = AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: start, duration: CMTime(value: 1, timescale: targetTimeScale))
            )

            // 别的轨刚搬完，这一条可能还没从上一次状态里缓过来，短等一下再写
            var waited = 0
            while !metadataInput.isReadyForMoreMediaData && waited < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            stillTimeWritten = metadataInput.isReadyForMoreMediaData && adaptor.append(group)
            metadataInput.markAsFinished()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            try? manager.removeItem(at: outputURL)
            throw LivePhotoError.exportFailed(writer.error?.localizedDescription ?? "重封装失败")
        }
        if reader.status == .failed {
            try? manager.removeItem(at: outputURL)
            throw LivePhotoError.exportFailed(reader.error?.localizedDescription ?? "读取源视频失败")
        }

        // MARK: 回读校验

        let written = AVURLAsset(url: outputURL)
        guard let writtenTrack = try await written.loadTracks(withMediaType: .video).first else {
            try? manager.removeItem(at: outputURL)
            throw LivePhotoError.exportFailed("重封装后的文件里没有视频轨")
        }
        let scale = try await writtenTrack.load(.naturalTimeScale)
        let duration = try await written.load(.duration).seconds

        guard abs(duration - ClipSelection.wallpaperDuration) < 0.01 else {
            try? manager.removeItem(at: outputURL)
            throw LivePhotoError.exportFailed("重封装后时长变成了 \(Formatters.duration(duration))")
        }

        var notes: [String] = []
        // 只要是 600 的整数倍就能精确表示 550/600；不是的话时长本身可能仍对，
        // 但壁纸判定可能不认，如实说明。
        let timeScaleOK = scale > 0 && scale % targetTimeScale == 0
        if !timeScaleOK {
            notes.append("视频轨时间基是 \(scale)，不是 600 的整数倍")
        }
        if !stillTimeWritten {
            notes.append("封面帧标记（still-image-time）没能写入")
        }

        return Output(
            url: outputURL,
            timeScale: scale,
            timeScaleOK: timeScaleOK,
            stillTimeWritten: stillTimeWritten,
            note: notes.isEmpty ? nil : notes.joined(separator: "；")
        )
    }

    // MARK: - 样本搬运

    /// 把一条轨的样本原样搬到新文件里，需要时顺手把时间戳换算到目标时间基。
    ///
    /// 回调可能被 `requestMediaDataWhenReady` 反复唤起（每次「暂时喂不动了」就退出，
    /// 等能喂了再来），所以只有在读到结尾或写入失败时才调 `completion`，并且只调一次。
    private static func pump(
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        queue: DispatchQueue,
        retime: Bool,
        completion: @escaping () -> Void
    ) {
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    completion()
                    return
                }
                let outgoing = retime ? retimed(sample, timescale: targetTimeScale) : sample
                guard let outgoing, input.append(outgoing) else {
                    input.markAsFinished()
                    completion()
                    return
                }
            }
        }
    }

    /// 把样本的时间戳换算到目标时间基。
    ///
    /// `AVAssetWriter` 会用**第一个样本的时间戳时间基**作为这条轨的媒体时间基，
    /// 所以只要把 PTS 全部换算到 600，落盘出来就等价于
    /// `-video_track_timescale 600`。
    private static func retimed(_ sample: CMSampleBuffer, timescale: CMTimeScale) -> CMSampleBuffer? {
        // 视频轨上每个 buffer 是一帧。真遇到多帧的就不动它——
        // 只给一个 timing 条目会把多帧的时间数组搞错位，宁可少一层转换。
        guard CMSampleBufferGetNumSamples(sample) == 1 else { return sample }

        let pts = CMTimeConvertScale(
            sample.presentationTimeStamp,
            timescale: timescale,
            method: .roundHalfAwayFromZero
        )

        var duration = sample.duration
        if duration.isNumeric, duration.seconds > 0 {
            duration = CMTimeConvertScale(duration, timescale: timescale, method: .roundHalfAwayFromZero)
        } else {
            duration = CMTime(value: 1, timescale: timescale)
        }

        // 有 B 帧时 DTS 也是有效信息，一并换算，别丢
        let decodeStamp = sample.decodeTimeStamp
        let dts = decodeStamp.isValid
            ? CMTimeConvertScale(decodeStamp, timescale: timescale, method: .roundHalfAwayFromZero)
            : CMTime.invalid

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var converted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &converted
        )
        return status == noErr ? converted : nil
    }

    // MARK: - still-image-time 轨的格式描述

    /// 构造 still-image-time 时间元数据轨的格式描述。
    ///
    /// 这条轨的声明方式是固定的：标识 `mdta/com.apple.quicktime.still-image-time`，
    /// 数据类型是 int8（值恒为 0，帧号本身由**样本的时间位置**表达）。
    private static func stillImageTimeFormatDescription() -> CMFormatDescription? {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }
}

/// 数到零就放行一次。两条轨的搬运是并发跑的，需要一个带锁的计数器汇总完成情况，
/// 否则先到的那条会提前把 continuation 用掉。
private final class PendingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ remaining: Int) {
        self.remaining = max(1, remaining)
    }

    /// - Returns: true 表示这是最后一次递减，调用方可以 resume。
    func decrementReachedZero() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        remaining -= 1
        return remaining <= 0
    }
}
