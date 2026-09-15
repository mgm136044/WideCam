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
        let stem = "WideCam_\(formatter.string(from: date))"
        let candidate = baseDirectory.appendingPathComponent("\(stem).\(fileExtension)")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        // 파일명 해상도는 1초다. 같은 초에 두 번 찍으면 뒤의 것이 앞의 것을 덮어써
        // 조용한 데이터 손실이 된다(설계 §9). 빈 이름을 찾을 때까지 _2, _3 … 을 붙인다.
        var suffix = 2
        while true {
            let numbered = baseDirectory.appendingPathComponent("\(stem)_\(suffix).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: numbered.path) { return numbered }
            suffix += 1
        }
    }
}
