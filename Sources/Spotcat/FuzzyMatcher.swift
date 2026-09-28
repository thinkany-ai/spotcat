/// 子序列模糊匹配，偏好：开头命中、单词/驼峰边界命中、连续命中、较短的目标。
/// 用 DP 找最优对齐，"vsc" 能命中 "Visual Studio Code" 的三个词首。
enum FuzzyMatcher {
    private static let impossible = Int.min / 2

    static func score(query: [Character], in target: String) -> Int? {
        let lower = Array(target.lowercased())
        let original = Array(target)
        let n = lower.count
        let m = query.count
        guard m > 0, m <= n else { return nil }

        // 大小写转换改变长度时（极少见）放弃驼峰判断
        let canDetectCamel = original.count == n
        let charBonus: [Int] = (0..<n).map { i in
            if i == 0 { return 25 }
            let prev = lower[i - 1]
            if prev == " " || prev == "-" || prev == "_" || prev == "." { return 22 }
            if canDetectCamel, original[i - 1].isLowercase, original[i].isUppercase { return 20 }
            if prev.isLetter != lower[i].isLetter { return 16 }
            return 10
        }

        // prev[i]：query[0...j-1] 已匹配，且 query[j-1] 落在 target[i] 时的最高分
        var prev = [Int](repeating: impossible, count: n)
        for j in 0..<m {
            var cur = [Int](repeating: impossible, count: n)
            var bestBeforeGap = impossible // max(prev[0..<i-1])
            for i in 0..<n {
                if i >= 2 { bestBeforeGap = max(bestBeforeGap, prev[i - 2]) }
                guard lower[i] == query[j] else { continue }

                if j == 0 {
                    cur[i] = charBonus[i] - min(i, 5)
                    continue
                }
                var best = impossible
                if i >= 1, prev[i - 1] > impossible { best = prev[i - 1] + 8 } // 连续命中
                if bestBeforeGap > impossible { best = max(best, bestBeforeGap - 3) } // 有间隔
                if best > impossible { cur[i] = best + charBonus[i] }
            }
            prev = cur
        }

        guard let best = prev.max(), best > impossible else { return nil }
        var total = best
        if lower.starts(with: query) { total += 20 }
        return total - n / 5
    }
}
