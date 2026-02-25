import Testing
import Foundation
@testable import Memo

struct DateHelpersTests {

    // MARK: - ISO 8601

    @Test func iso8601RoundTrip() {
        let now = Date()
        let str = now.iso8601String
        let parsed = Date(iso8601: str)
        #expect(parsed != nil)
        // ISO 8601 truncates to seconds
        #expect(abs(parsed!.timeIntervalSince(now)) < 1.0)
    }

    @Test func iso8601InvalidString() {
        let bad = Date(iso8601: "not-a-date")
        #expect(bad == nil)
    }

    @Test func iso8601EmptyString() {
        let empty = Date(iso8601: "")
        #expect(empty == nil)
    }

    // MARK: - timeOnlyString

    @Test func timeOnlyFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 2
        components.day = 26
        components.hour = 14
        components.minute = 5
        let date = Calendar.current.date(from: components)!
        #expect(date.timeOnlyString == "14:05")
    }

    @Test func timeOnlyMidnight() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        let date = Calendar.current.date(from: components)!
        #expect(date.timeOnlyString == "00:00")
    }
}
