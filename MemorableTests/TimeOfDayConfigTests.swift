import XCTest
@testable import Memorable

final class TimeOfDayConfigTests: XCTestCase {

    func testBreakfastDetection() {
        let result = TimeOfDayConfig.detect(in: "breakfast at hotel")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 5)
        XCTAssertEqual(result?.end, 10)
    }

    func testMorningCoffee() {
        let result = TimeOfDayConfig.detect(in: "morning coffee")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 5)
    }

    func testLunch() {
        let result = TimeOfDayConfig.detect(in: "lunch with team")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 11)
        XCTAssertEqual(result?.end, 14)
    }

    func testDinner() {
        let result = TimeOfDayConfig.detect(in: "dinner last week")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 18)
        XCTAssertEqual(result?.end, 22)
    }

    func testSunset() {
        let result = TimeOfDayConfig.detect(in: "sunset over ocean")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 18)
    }

    func testNight() {
        let result = TimeOfDayConfig.detect(in: "night sky")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 20)
        XCTAssertEqual(result?.end, 4) // wraps midnight
    }

    func testLateNight() {
        let result = TimeOfDayConfig.detect(in: "late night snack")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 20)
    }

    func testSunrise() {
        let result = TimeOfDayConfig.detect(in: "sunrise hike")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 5)
    }

    func testBrunch() {
        let result = TimeOfDayConfig.detect(in: "brunch with friends")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 9)
        XCTAssertEqual(result?.end, 12)
    }

    func testNoTimeOfDay() {
        let result = TimeOfDayConfig.detect(in: "dog playing in park")
        XCTAssertNil(result)
    }

    func testNoPartialMatch() {
        // "sun" in "sunflower" should not match "sunrise"
        let result = TimeOfDayConfig.detect(in: "sunflower field")
        XCTAssertNil(result)
    }
}
