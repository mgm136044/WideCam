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
