import Foundation

/// 카메라가 노출하는 포맷 하나를 UI/정책 계층에서 다루기 위한 값 타입.
struct FormatSpec: Equatable, Hashable, Identifiable {
    let width: Int
    let height: Int
    let maxFrameRate: Double

    var id: String { "\(width)x\(height)@\(Int(maxFrameRate))" }
    var isFourThree: Bool { width * 3 == height * 4 }
    var pixelCount: Int { width * height }

    var label: String {
        let ratio: String
        if isFourThree { ratio = "4:3" }
        else if width * 9 == height * 16 { ratio = "16:9" }
        else { ratio = "\(width):\(height)" }
        return "\(width)×\(height) · \(ratio) · 최대 \(Int(maxFrameRate))fps"
    }
}

enum FormatPolicy {
    /// 중복 제거 후 해상도 내림차순(같은 해상도는 fps 오름차순) 정렬.
    static func specs(fromDimensions dims: [(width: Int, height: Int, maxFrameRate: Double)]) -> [FormatSpec] {
        let unique = Set(dims.map { FormatSpec(width: $0.width, height: $0.height, maxFrameRate: $0.maxFrameRate) })
        return unique.sorted {
            if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
            return $0.maxFrameRate < $1.maxFrameRate
        }
    }

    /// 기본값: 화각이 가장 넓은 4:3 최대 해상도, fps는 30 이상 중 최소(발열·용량 균형).
    static func defaultSpec(in specs: [FormatSpec]) -> FormatSpec? {
        let fourThree = specs.filter(\.isFourThree)
        let pool = fourThree.isEmpty ? specs : fourThree
        guard let maxPixels = pool.map(\.pixelCount).max() else { return nil }
        let candidates = pool.filter { $0.pixelCount == maxPixels }
        return candidates.first { $0.maxFrameRate >= 30 } ?? candidates.last
    }
}
