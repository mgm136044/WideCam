import Foundation

/// 촬영물 저장 경로와 파일명을 만드는 순수 로직.
struct MediaStore {
    let baseDirectory: URL

    /// 사진 폴더를 못 찾았을 때 첨자로 트랩하면 앱이 창 하나 띄우기 전에 죽고 사용자는
    /// 이유를 알 수 없다(이 기본 인자는 CameraManager의 프로퍼티 초기화에서 평가된다).
    /// 홈 아래 Pictures로 떨어뜨린다.
    static var defaultBaseDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("WideCam", isDirectory: true)
    }

    /// 파일명 stem을 만드는 포매터. DateFormatter 생성은 0.3~1밀리초라 호출마다 만들
    /// 이유가 없다. 설정을 바꾸지 않고 문자열만 만들므로 공유해도 안전하다.
    private static let stemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    init(baseDirectory: URL = MediaStore.defaultBaseDirectory) {
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
        let stem = "WideCam_\(Self.stemFormatter.string(from: date))"
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
