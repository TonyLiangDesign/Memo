import Foundation

extension Date {
    /// ISO 8601 formatted string (aligned with EverMemOS create_time)
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }

    /// Initialize from ISO 8601 string
    init?(iso8601 string: String) {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else { return nil }
        self = date
    }

    /// Localized relative time: "刚刚", "5分钟前", "今天 14:30"
    var relativeString: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        if interval < 60 {
            return String(localized: "刚刚")
        } else if interval < 3600 {
            return String(localized: "\(Int(interval / 60))分钟前")
        } else if Calendar.current.isDateInToday(self) {
            let formatter = DateFormatter()
            formatter.dateFormat = String(localized: "日期格式_今天")
            return formatter.string(from: self)
        } else if Calendar.current.isDateInYesterday(self) {
            let formatter = DateFormatter()
            formatter.dateFormat = String(localized: "日期格式_昨天")
            return formatter.string(from: self)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = String(localized: "日期格式_其他")
            return formatter.string(from: self)
        }
    }

    @available(*, deprecated, renamed: "relativeString")
    var relativeChineseString: String { relativeString }

    /// Time-only string: "20:05"
    var timeOnlyString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }
}
