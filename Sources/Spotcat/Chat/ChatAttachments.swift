import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 附件只通过用户主动选择的文件读取；图片归一化为 PNG，其余附件提取文本。
enum ChatAttachments {
    static let maxFileSize = 10 * 1024 * 1024

    static func pick(in window: NSWindow?, limit: Int, reply: @escaping WebBridge.Reply) {
        guard let window, limit > 0 else { return reply(nil, L10n.t("chat.attachments.unavailable")) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return reply(["attachments": [], "errors": []], nil) }
            let urls = panel.urls
            let limit = min(limit, 4)
            DispatchQueue.global(qos: .userInitiated).async {
                var attachments: [[String: Any]] = []
                var errors = urls.count > limit ? [L10n.t("chat.attachments.limit")] : []
                for url in urls.prefix(limit) {
                    do { attachments.append(try load(url)) }
                    catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                DispatchQueue.main.async { reply(["attachments": attachments, "errors": errors], nil) }
            }
        }
    }

    static func load(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = values.fileSize ?? 0
        guard size <= maxFileSize else { throw AttachmentError(message: L10n.t("chat.attachments.tooLarge")) }
        var attachment: [String: Any] = ["id": UUID().uuidString, "name": url.lastPathComponent, "size": size]
        if values.contentType?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw AttachmentError(message: L10n.t("chat.attachments.unreadable"))
            }
            let image = try png(source, maxPixelSize: 2048)
            guard image.count <= maxFileSize else { throw AttachmentError(message: L10n.t("chat.attachments.tooLarge")) }
            let dataURL = "data:image/png;base64," + image.base64EncodedString()
            attachment["content"] = ["type": "image_url", "image_url": ["url": dataURL]]
            attachment["preview"] = "data:image/png;base64," + (try png(source, maxPixelSize: 144)).base64EncodedString()
        } else {
            let text = try AgentTools.run(name: "read_file", arguments: ["path": url.path])
            attachment["content"] = ["type": "text", "text": "Attached file: \(url.lastPathComponent)\nPath: \(url.path)\n\n\(text)"]
        }
        return attachment
    }

    private static func png(_ source: CGImageSource, maxPixelSize: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AttachmentError(message: L10n.t("chat.attachments.unreadable"))
        }
        return data
    }

    private struct AttachmentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
