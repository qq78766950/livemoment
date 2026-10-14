import AVFoundation
import Combine
import Foundation
import UIKit

/// 相机拍摄：录一段带声音的短片，交给编辑器接着做成实况照片。
///
/// 用 `AVCaptureMovieFileOutput` 直接录成 MOV，而不是自己拿
/// `AVCaptureVideoDataOutput` 拼 AVAssetWriter——因为录出来的素材马上要进
/// `AVMutableComposition` 做裁剪与变速，交给系统写一个标准的 H.264/H.265 MOV
/// 比手工拼帧可靠得多，也少一整层出错的地方。
///
/// 线程约定：`session` 的配置与启停全部丢到私有串行队列上（`AVCaptureSession`
/// 的启停是阻塞调用，放主线程会卡界面），界面状态一律回主线程更新。
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: - 对外状态

    /// 会话是否已经跑起来、可以开始预览。
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    /// 已录制时长（秒），录制中每 0.1 秒刷新一次。
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var position: AVCaptureDevice.Position = .back
    /// 录制结束后的文件地址。界面观察它来跳转。
    @Published private(set) var capturedURL: URL?
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    /// 单次录制上限。实况照片的动态只有几秒，录太久只会让后面的裁剪更费事。
    static let maxRecordDuration: Double = 15.0

    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.example.livemoment.camera")
    private var isConfigured = false
    private var recordStartedAt: Date?
    private var ticker: Timer?

    // MARK: - 权限

    /// 请求摄像头与麦克风权限。麦克风被拒不算致命——只是录出来没有声音。
    ///
    /// 必须在 `startRunning()` **之前**调用：系统不会因为会话启动而自动弹窗，
    /// 没权限的话预览是黑的、录出来是空文件，还不报错，很难查。
    static func requestAccess() async -> (camera: Bool, microphone: Bool) {
        let camera = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
        }
        let microphone = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        return (camera, microphone)
    }

    // MARK: - 生命周期

    /// 先要权限再开会话，界面不用自己拼这两步的顺序。
    ///
    /// 麦克风没授权时不会挂音轨——避免留一条永远没数据的轨把整段录制成空文件。
    ///
    /// - Returns: 摄像头与麦克风的授权结果，界面据此决定要不要提示。
    ///
    /// 标 `@MainActor`：`await` 之后会落到后台线程，而 `errorMessage` 是
    /// `@Published`，必须回主线程改，否则运行时会警告「Publishing changes from
    /// background threads is not allowed」。
    @MainActor
    @discardableResult
    func startAfterRequestingAccess() async -> (camera: Bool, microphone: Bool) {
        let granted = await Self.requestAccess()
        guard granted.camera else {
            errorMessage = "没有相机权限。请到「设置 → 隐私与安全性 → 相机」里允许「实况录影」，再回来拍摄。"
            return granted
        }
        errorMessage = nil
        start(audioAllowed: granted.microphone)
        return granted
    }

    func start(audioAllowed: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.configureIfNeeded(audioAllowed: audioAllowed) else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isReady = false
                self.stopTicker()
                self.isRecording = false
            }
        }
    }

    // MARK: - 录制

    func toggleRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard self.session.isRunning else { return }

            self.beginRecordingAudioSession()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveMomentCapture-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)

            DispatchQueue.main.async {
                self.isRecording = true
                self.elapsed = 0
                self.recordStartedAt = Date()
                self.startTicker()
            }
        }
    }

    func flip() {
        let wanted: AVCaptureDevice.Position = position == .back ? .front : .back
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wanted),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.errorMessage = "切换摄像头失败。" }
                return
            }

            self.session.beginConfiguration()
            // 只摘掉视频输入，麦克风那条要留着，
            // 否则切一次摄像头之后录出来的片段就变成无声的了
            for existing in self.session.inputs {
                guard let deviceInput = existing as? AVCaptureDeviceInput,
                      deviceInput.device.hasMediaType(.video) else { continue }
                self.session.removeInput(deviceInput)
            }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.position = wanted
                // 前置摄像头要镜像，否则自拍出来是反的
                self.applyMirroring()
            }
        }
    }

    /// 设备方向变化时更新录制轨的旋转角。预览层的角度由视图自己维护。
    func updateVideoRotation(angle: CGFloat) {
        queue.async { [weak self] in
            guard let self,
                  let connection = self.movieOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
            DispatchQueue.main.async { self.applyMirroring() }
        }
    }

    /// `UIDeviceOrientation` → `AVCaptureVideoOrientation` 对应的旋转角。
    ///
    /// 注意这里有个老坑：设备方向与界面方向正好相反——
    /// 设备转到 `.landscapeLeft`（顶部朝左）时，界面方向是 `.landscapeRight`。
    /// 所以映射时要「翻」一次，直接照抄同名值会把横屏视频转 180°。
    static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        default:
            return 90
        }
    }

    // MARK: - 配置

    /// - Parameter audioAllowed: 麦克风没授权时传 false，就不挂音轨。
    /// - Returns: 配置是否可用（拿到摄像头）。
    private func configureIfNeeded(audioAllowed: Bool) -> Bool {
        if isConfigured { return true }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.errorMessage = "这台设备上没有可用的摄像头。模拟器需要手动指定相机输入。"
            }
            return false
        }
        session.addInput(videoInput)

        // 麦克风没授权或拿不到，都不阻断拍摄，只是成片没有声音
        if audioAllowed,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "无法把录制输出接到相机会话上。" }
            return false
        }
        session.addOutput(movieOutput)
        movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxRecordDuration, preferredTimescale: 600)

        session.commitConfiguration()
        isConfigured = true

        DispatchQueue.main.async {
            if let connection = self.movieOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.applyMirroring()
        }
        return true
    }

    private func applyMirroring() {
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = position == .front
    }

    // MARK: - 音频会话

    /// 录制前把音频会话切到「录音 + 摄像」，否则录出来的文件没有音轨。
    private func beginRecordingAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.record, mode: .videoRecording, options: [])
        try? audio.setActive(true)
    }

    /// 录完切回播放，编辑器里的 `AVPlayer` 预览才出得了声。
    private func endRecordingAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .default, options: [])
        try? audio.setActive(true)
    }

    // MARK: - 计时

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.recordStartedAt else { return }
            self.elapsed = min(Date().timeIntervalSince(startedAt), Self.maxRecordDuration)
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        recordStartedAt = nil
    }
}

// MARK: - 录制回调

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // 起录无需处理，界面状态在 toggleRecording 里已经切了
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // 「到了时长上限」也会走带 error 的这条路，但文件是好的。
        // 系统用 AVErrorRecordingSuccessfullyFinishedKey 告诉我们该不该当真。
        let finishedCleanly = (error as NSError?)?
            .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)

        DispatchQueue.main.async {
            self.stopTicker()
            self.isRecording = false
            self.endRecordingAudioSession()

            let exists = FileManager.default.fileExists(atPath: outputFileURL.path)
            guard finishedCleanly, exists else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.errorMessage = "录制失败：\(error?.localizedDescription ?? "没有产出文件")"
                return
            }
            self.capturedURL = outputFileURL
        }
    }
}
