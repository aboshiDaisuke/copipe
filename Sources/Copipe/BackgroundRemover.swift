import CoreImage
import Vision

/// 画像の背景を消す（写真アプリの「被写体を持ち上げる」と同じ、Mac の中だけで動く機能）
enum BackgroundRemover {
    enum Failure: LocalizedError {
        case noSubject

        var errorDescription: String? { "切り抜けるもの（人・動物・物）が見つかりませんでした。" }
    }

    /// 背景を透明にした画像を返す。時間がかかるので、メインスレッドの外で呼ぶ
    static func cutout(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(masked, from: masked.extent) else { throw Failure.noSubject }
        return output
    }
}
