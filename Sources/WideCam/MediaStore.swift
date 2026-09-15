import Foundation

/// 촬영물 저장 경로와 파일명을 만드는 순수 로직.
struct MediaStore {
    let baseDirectory: URL

    init(baseDirectory: URL = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WideCam", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    func photoURL(at date: Date = Date(), fileExtension: String = "heic") -> URL {
        fileURL(date: date, fileExtension: fileExtension)
    }

    func movieURL(at date: Date = Date()) -> URL {
        fileURL(date: date, fileExtension: "mov")
    }

    private func fileURL(date: Date, fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return baseDirectory.appendingPathComponent("WideCam_\(formatter.string(from: date)).\(fileExtension)")
    }
}
