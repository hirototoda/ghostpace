import Foundation

/// 時間の表示形式。
enum DurationFormat {
    /// タイマー表示。1時間以上は `1:17:00`、未満は `23:10`。
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 数字と単位の組。`5400` → [("1", "時間"), ("30", "分")]。1分未満は切り捨て。
    static func parts(_ seconds: Int) -> [(number: String, unit: String)] {
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return [("\(m)", "分")] }
        if m == 0 { return [("\(h)", "時間")] }
        return [("\(h)", "時間"), (String(format: "%02d", m), "分")]
    }

    /// 文章中の表示。`5400` → `1時間30分`。
    static func japanese(_ seconds: Int) -> String {
        parts(seconds).map { $0.number + $0.unit }.joined()
    }

    /// 差の表示。`1500` → `+25分`、`-3300` → `−55分`。
    static func signed(_ seconds: Int) -> String {
        sign(seconds) + japanese(seconds)
    }

    static func sign(_ seconds: Int) -> String {
        seconds >= 0 ? "+" : "−"
    }
}
