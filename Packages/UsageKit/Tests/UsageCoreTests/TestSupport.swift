import Foundation
import XCTest

/// A UTC date built without ISODate, so date tests do not grade their own homework.
func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, frac: Double = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    return base.addingTimeInterval(frac)
}

func fixture(_ name: String, ext: String = "json") throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
        "missing fixture \(name)"
    )
    return try Data(contentsOf: url)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usagekit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct IndexMissing: Error, CustomStringConvertible {
    let index: Int
    let count: Int
    var description: String { "no element \(index) in \(count) elements" }
}

extension Array {
    /// A checked index, so a wrong result fails the test instead of trapping
    /// and taking every other test in the bundle down with it.
    subscript(at index: Int) -> Element {
        get throws {
            guard indices.contains(index) else { throw IndexMissing(index: index, count: count) }
            return self[index]
        }
    }
}
