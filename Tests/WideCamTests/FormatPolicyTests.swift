import Testing
@testable import WideCam

@Test func 아이폰_실측_포맷목록에서_기본값은_1920x1440_30fps다() {
    let dims: [(width: Int, height: Int, maxFrameRate: Double)] = [
        (640, 480, 30), (640, 480, 60),
        (1280, 720, 30), (1280, 720, 60),
        (1920, 1080, 30), (1920, 1080, 60),
        (1920, 1440, 30), (1920, 1440, 60),
    ]
    let specs = FormatPolicy.specs(fromDimensions: dims)
    #expect(specs.count == 8)
    #expect(specs.first?.pixelCount == 1920 * 1440)
    #expect(FormatPolicy.defaultSpec(in: specs) == FormatSpec(width: 1920, height: 1440, maxFrameRate: 30))
}

@Test func 중복_포맷은_제거된다() {
    let specs = FormatPolicy.specs(fromDimensions: [(1920, 1080, 30), (1920, 1080, 30)])
    #expect(specs.count == 1)
}

@Test func 사대삼이_없으면_전체에서_최대해상도를_고른다() {
    let specs = FormatPolicy.specs(fromDimensions: [(1920, 1080, 30), (1280, 720, 60)])
    #expect(FormatPolicy.defaultSpec(in: specs) == FormatSpec(width: 1920, height: 1080, maxFrameRate: 30))
}

@Test func 라벨은_해상도_비율_fps를_포함한다() {
    let spec = FormatSpec(width: 1920, height: 1440, maxFrameRate: 60)
    #expect(spec.label == "1920×1440 · 4:3 · 최대 60fps")
    #expect(spec.isFourThree)
}
