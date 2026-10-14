import AVFoundation
import SwiftUI
import UIKit

// MARK: - 相机预览

/// 直接把 `AVCaptureVideoPreviewLayer` 当 backing layer 用，省一层手动布局。
final class CameraPreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// 预览画面的旋转角（度），由外部按设备方向传入。
    let rotationAngle: CGFloat

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        applyRotation(to: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewHostView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        applyRotation(to: uiView)
    }

    private func applyRotation(to view: CameraPreviewHostView) {
        guard let connection = view.previewLayer.connection,
              connection.isVideoRotationAngleSupported(rotationAngle) else { return }
        connection.videoRotationAngle = rotationAngle
    }
}

// MARK: - 拍摄页

/// 相机拍摄页：录一段带声音的短片，录完直接交给编辑器做成实况照片。
///
/// 走编辑器而不是「拍完立刻生成」，是因为实况照片的动态只有几秒，
/// 而刚拍完的素材往往前摇后摇都留着——让人先看一眼、拖一下选区，
/// 比替他猜要靠谱。想省事的话进去直接点「生成实况照片」就行。
struct CameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    /// 录制完成回调。由调用方决定怎么处理这个文件。
    let onFinish: (URL) -> Void

    @StateObject private var recorder = CameraRecorder()
    @State private var rotationAngle: CGFloat = 90

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if recorder.isReady {
                CameraPreviewView(session: recorder.session, rotationAngle: rotationAngle)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("正在启动相机…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                hint
                controls
            }
        }
        .statusBarHidden(false)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            recorder.start()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            recorder.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let next = CameraRecorder.rotationAngle(for: UIDevice.current.orientation)
            guard next != rotationAngle else { return }
            rotationAngle = next
            recorder.updateVideoRotation(angle: next)
        }
        .onChange(of: recorder.capturedURL) { _, url in
            guard let url else { return }
            onFinish(url)
            dismiss()
        }
        .alert("拍摄遇到问题", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(String(format: "%.1f s", recorder.elapsed))
                        .font(.footnote.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
            }

            Spacer()

            Button {
                recorder.flip()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isRecording)
            .opacity(recorder.isRecording ? 0.4 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    // MARK: - 提示

    private var hint: some View {
        Text("建议拍 2～3 秒。录完会进入编辑器，可以拖选区、调快慢，再生成实况照片。")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
    }

    // MARK: - 底部控件

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                recorder.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 29, style: .continuous)
                        .fill(Color.red)
                        .frame(
                            width: recorder.isRecording ? 30 : 58,
                            height: recorder.isRecording ? 30 : 58
                        )
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: recorder.isRecording)
                }
            }
            .buttonStyle(.plain)
            .disabled(!recorder.isReady)

            Text(recorder.isRecording ? "轻点停止" : "轻点开始录制")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 28)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )
    }
}
