import Foundation
import Testing
@testable import WideCam

@Test func 사진과_영상_파일명은_타임스탬프_형식이다() {
    let store = MediaStore(baseDirectory: URL(fileURLWithPath: "/tmp/widecam-test"))
    var comps = DateComponents()
    comps.year = 2026; comps.month = 9; comps.day = 15
    comps.hour = 14; comps.minute = 30; comps.second = 12
    let date = Calendar(identifier: .gregorian).date(from: comps)!
    #expect(store.photoURL(at: date).lastPathComponent == "WideCam_20260915_143012.heic")
    #expect(store.photoURL(at: date, fileExtension: "jpg").lastPathComponent == "WideCam_20260915_143012.jpg")
    #expect(store.movieURL(at: date).lastPathComponent == "WideCam_20260915_143012.mov")
}

@Test func 저장_디렉터리_기본값은_Pictures_WideCam이다() {
    let store = MediaStore()
    #expect(store.baseDirectory.path.hasSuffix("Pictures/WideCam"))
}

/// 같은 초에 두 번 찍으면 파일명이 겹친다. 뒤에 찍은 것이 앞의 것을 덮어쓰지 않도록
/// 이미 존재하는 이름이면 _2, _3 … 을 붙인다(설계 §9: 조용한 데이터 손실 금지).
@Test func 같은_초에_찍으면_파일명_뒤에_번호가_붙는다() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("widecam-collision-\(UUID().uuidString)", isDirectory: true)
    let store = MediaStore(baseDirectory: base)
    try store.ensureDirectoryExists()
    defer { try? FileManager.default.removeItem(at: base) }

    var comps = DateComponents()
    comps.year = 2026; comps.month = 9; comps.day = 15
    comps.hour = 14; comps.minute = 30; comps.second = 12
    let date = Calendar(identifier: .gregorian).date(from: comps)!

    // 비어 있을 때는 번호가 붙지 않는다.
    #expect(store.photoURL(at: date).lastPathComponent == "WideCam_20260915_143012.heic")

    try Data().write(to: base.appendingPathComponent("WideCam_20260915_143012.heic"))
    #expect(store.photoURL(at: date).lastPathComponent == "WideCam_20260915_143012_2.heic")

    try Data().write(to: base.appendingPathComponent("WideCam_20260915_143012_2.heic"))
    #expect(store.photoURL(at: date).lastPathComponent == "WideCam_20260915_143012_3.heic")

    // 확장자가 다르면 충돌이 아니다.
    #expect(store.movieURL(at: date).lastPathComponent == "WideCam_20260915_143012.mov")
}
