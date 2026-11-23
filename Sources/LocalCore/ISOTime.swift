import Foundation

/// Fast ISO-8601 parser for `2026-01-01T12:00:00.000Z` / `+03:00` variants. Unix seconds.
public enum ISOTime {
    public static func parse(_ s: String) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19 else { return nil }

        // Reads `len` ASCII digits, or nil when they would fall outside the buffer.
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from >= 0, from + len <= u.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = u[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }

        guard let y = num(0, 4), u[4] == 45, let mo = num(5, 2), u[7] == 45, let d = num(8, 2),
              u[10] == 84 || u[10] == 32, let h = num(11, 2), u[13] == 58, let mi = num(14, 2),
              u[16] == 58, let sec = num(17, 2) else { return nil }

        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == 46 {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                frac += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }

        var offset = 0
        if i < u.count, u[i] == 43 || u[i] == 45 {
            let sign = u[i] == 43 ? 1 : -1
            // A sign with digits that do not fit the buffer is malformed, not a zero offset.
            guard let oh = num(i + 1, 2) else { return nil }
            let om: Int
            if i + 3 < u.count, u[i + 3] == 58 {
                guard let m = num(i + 4, 2) else { return nil }
                om = m
            } else {
                guard let m = num(i + 3, 2) else { return nil }
                om = m
            }
            offset = sign * (oh * 3600 + om * 60)
        }

        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + sec - offset) + frac
    }
}
