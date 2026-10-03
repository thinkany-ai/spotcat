import AppKit

/// 计算器：输入算式（1+2*3、sqrt(2)、2^10、15%）或单位换算（10 km to mi、100f to c）时直接显示结果，↩ 复制
final class Calculator: BuiltinExtension {
    let id = "builtin.calculator"
    var name: String { L10n.t("calculator.name") }
    var description: String { L10n.t("calculator.description") }
    let icon: (symbol: String, color: NSColor) = ("plus.forwardslash.minus", .systemOrange)

    func answers(for text: String) -> [BuiltinAnswer] {
        guard text.count <= 200, !Self.looksLikeNonMath(text) else { return [] }

        if let conversion = UnitConversion.parse(text), let value = conversion.evaluate() {
            let result = NumberDisplay.format(value)
            return [BuiltinAnswer(
                extensionID: id,
                title: "\(result.display) \(conversion.target.symbol)",
                subtitle: "\(NumberDisplay.format(conversion.value).display) \(conversion.source.symbol)",
                copyText: result.plain
            )]
        }

        guard let parsed = try? MathExpression.evaluate(text), parsed.hasOperation, parsed.value.isFinite else { return [] }
        let result = NumberDisplay.format(parsed.value)
        return [BuiltinAnswer(extensionID: id, title: result.display, subtitle: text, copyText: result.plain)]
    }

    /// 日期（2026-10-01）、电话号码（138-1234-5678）、版本号这类虽然能算，但显然不是想算
    private static let nonMathPattern = try! NSRegularExpression(pattern: #"^\d+([-/.])\d+\1\d+$"#)

    private static func looksLikeNonMath(_ text: String) -> Bool {
        nonMathPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - 数字显示

enum NumberDisplay {
    /// display 带千分位，用于显示；plain 不带，用于复制
    static func format(_ value: Double) -> (display: String, plain: String) {
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-9 {
            let text = String(format: "%.10g", value)
            return (text, text)
        }
        // 去掉浮点误差（0.1+0.2）
        let rounded = (value * 1e10).rounded() / 1e10
        return (formatter(grouping: true).string(from: rounded as NSNumber) ?? "\(rounded)",
                formatter(grouping: false).string(from: rounded as NSNumber) ?? "\(rounded)")
    }

    private static func formatter(grouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.maximumFractionDigits = 10
        return formatter
    }
}

// MARK: - 表达式

/// 递归下降解析：+ - * / × ÷ ^ % mod ! 括号、隐式乘法（2pi、2(3+4)）、常量和常用函数。
/// 不用 NSExpression：它遇到非法输入会抛 ObjC 异常导致崩溃
struct MathExpression {
    enum ParseError: Error { case invalid }

    struct Result {
        let value: Double
        /// 是否真的做了运算；单独一个数字不算
        let hasOperation: Bool
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)
        case open, close, comma
    }

    private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]
    private static let functions: [String: ([Double]) -> Double?] = [
        "sqrt": unary(Foundation.sqrt), "cbrt": unary(Foundation.cbrt), "abs": unary(Swift.abs),
        "sin": unary(Foundation.sin), "cos": unary(Foundation.cos), "tan": unary(Foundation.tan),
        "asin": unary(Foundation.asin), "acos": unary(Foundation.acos), "atan": unary(Foundation.atan),
        "ln": unary(Foundation.log), "log": unary(Foundation.log10), "log2": unary(Foundation.log2), "exp": unary(Foundation.exp),
        "floor": unary(Foundation.floor), "ceil": unary(Foundation.ceil), "round": unary { $0.rounded() },
        "min": { $0.isEmpty ? nil : $0.min() }, "max": { $0.isEmpty ? nil : $0.max() },
        "pow": { $0.count == 2 ? Foundation.pow($0[0], $0[1]) : nil },
    ]

    private static func unary(_ f: @escaping (Double) -> Double) -> ([Double]) -> Double? {
        { $0.count == 1 ? f($0[0]) : nil }
    }

    private let tokens: [Token]
    private var position = 0
    private var operations = 0

    static func evaluate(_ text: String) throws -> Result {
        var parser = MathExpression(tokens: try tokenize(text))
        let value = try parser.parseExpression()
        guard parser.position == parser.tokens.count else { throw ParseError.invalid }
        return Result(value: value, hasOperation: parser.operations > 0)
    }

    private init(tokens: [Token]) {
        self.tokens = tokens
    }

    // MARK: 词法

    private static func tokenize(_ text: String) throws -> [Token] {
        // 全角符号和中文输入法常见写法
        let normalized = text.lowercased()
            .replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "＊", with: "*")
            .replacingOccurrences(of: "＋", with: "+").replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "／", with: "/").replacingOccurrences(of: "％", with: "%")
            .replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "−", with: "-")
        let chars = Array(normalized)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII, c.isNumber || c == "." {
                let (value, next) = try number(chars, from: i)
                tokens.append(.number(value))
                i = next
            } else if c.isASCII && c.isLetter || c == "π" {
                var j = i
                while j < chars.count, chars[j].isASCII && (chars[j].isLetter || chars[j].isNumber) || chars[j] == "π" { j += 1 }
                tokens.append(.identifier(String(chars[i..<j])))
                i = j
            } else {
                switch c {
                case "+", "-", "*", "/", "^", "%", "!": tokens.append(.op(c))
                case "×", "·": tokens.append(.op("*"))
                case "÷": tokens.append(.op("/"))
                case "(": tokens.append(.open)
                case ")": tokens.append(.close)
                case ",": tokens.append(.comma)
                default: throw ParseError.invalid
                }
                i += 1
            }
        }
        return tokens
    }

    /// 十进制（含 1e3 科学计数法）、0x 十六进制、0b 二进制、0o 八进制
    private static func number(_ chars: [Character], from start: Int) throws -> (Double, Int) {
        if chars[start] == "0", start + 1 < chars.count, let radix = ["x": 16, "b": 2, "o": 8][chars[start + 1]] {
            var j = start + 2
            while j < chars.count, chars[j].isHexDigit { j += 1 }
            guard j > start + 2, let value = Int(String(chars[(start + 2)..<j]), radix: radix) else { throw ParseError.invalid }
            return (Double(value), j)
        }
        var j = start
        while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "." { j += 1 }
        // 1e5 / 1e-5；后面不是数字时 e 是常量（2e = 2×e）
        if j < chars.count, chars[j] == "e" {
            var k = j + 1
            if k < chars.count, chars[k] == "-" || chars[k] == "+" { k += 1 }
            if k < chars.count, chars[k].isASCII, chars[k].isNumber {
                while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
                j = k
            }
        }
        guard let value = Double(String(chars[start..<j])) else { throw ParseError.invalid }
        return (value, j)
    }

    // MARK: 语法

    private var current: Token? { position < tokens.count ? tokens[position] : nil }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while case .op(let op)? = current, op == "+" || op == "-" {
            position += 1
            let rhs = try parseTerm()
            value = op == "+" ? value + rhs : value - rhs
            operations += 1
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseUnary()
        while true {
            if case .op(let op)? = current, op == "*" || op == "/" || op == "%" {
                position += 1
                let rhs = try parseUnary()
                value = op == "*" ? value * rhs : op == "/" ? value / rhs : value.truncatingRemainder(dividingBy: rhs)
            } else if case .identifier("mod")? = current {
                position += 1
                value = value.truncatingRemainder(dividingBy: try parseUnary())
            } else if case .identifier("x")? = current {
                // 3 x 4
                position += 1
                value *= try parseUnary()
            } else if startsOperand(current), current.map({ if case .number = $0 { return false } else { return true } }) == true {
                // 隐式乘法：2pi、2(3+4)、(1+2)(3+4)；两个数字之间不算（59 130 246、电话号码）
                value *= try parseUnary()
            } else {
                return value
            }
            operations += 1
        }
    }

    private func startsOperand(_ token: Token?) -> Bool {
        switch token {
        case .number, .open: return true
        case .identifier(let name): return name != "mod" && name != "x"
        default: return false
        }
    }

    private mutating func parseUnary() throws -> Double {
        if case .op(let op)? = current, op == "-" || op == "+" {
            position += 1
            let value = try parseUnary()
            return op == "-" ? -value : value
        }
        return try parsePower()
    }

    /// 右结合，且优先于一元负号：-2^2 = -4，2^3^2 = 512
    private mutating func parsePower() throws -> Double {
        let base = try parsePostfix()
        guard case .op("^")? = current else { return base }
        position += 1
        operations += 1
        return Foundation.pow(base, try parseUnary())
    }

    private mutating func parsePostfix() throws -> Double {
        var value = try parsePrimary()
        while case .op(let op)? = current {
            if op == "!" {
                guard value >= 0, value <= 170, value == value.rounded() else { throw ParseError.invalid }
                value = (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
            } else if op == "%", !startsOperand(next) {
                // 后面没有操作数时 % 是百分号（15% = 0.15），否则是取余
                value /= 100
            } else {
                break
            }
            position += 1
            operations += 1
        }
        return value
    }

    private var next: Token? { position + 1 < tokens.count ? tokens[position + 1] : nil }

    private mutating func parsePrimary() throws -> Double {
        switch current {
        case .number(let value)?:
            position += 1
            return value
        case .open?:
            position += 1
            let value = try parseExpression()
            guard current == .close else { throw ParseError.invalid }
            position += 1
            return value
        case .identifier(let name)?:
            position += 1
            if let constant = Self.constants[name] { return constant }
            guard let function = Self.functions[name], current == .open else { throw ParseError.invalid }
            position += 1
            var args: [Double] = []
            if current != .close {
                args.append(try parseExpression())
                while current == .comma {
                    position += 1
                    args.append(try parseExpression())
                }
            }
            guard current == .close, let value = function(args) else { throw ParseError.invalid }
            position += 1
            operations += 1
            return value
        default:
            throw ParseError.invalid
        }
    }
}

// MARK: - 单位换算

struct UnitConversion {
    struct Unit {
        enum Kind { case length, mass, temperature, data, time, volume, speed, area }
        let kind: Kind
        let symbol: String
        /// 换算到基准单位的系数；温度单独处理
        let factor: Double
        let aliases: [String]
    }

    let value: Double
    let source: Unit
    let target: Unit

    // "10 km to mi"、"(1+2)kg in lb"、"100 华氏度 转 摄氏度"
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.+?)\s*([a-zA-Z°/²\p{Han}]+[23²]?)\s*(?:to|in|as|=|->|→|转换成|转换为|转成|换成|转)\s*([a-zA-Z°/²\p{Han}]+[23²]?)$"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> UnitConversion? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), match.numberOfRanges == 4,
              let valueRange = Range(match.range(at: 1), in: text),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text),
              let source = unit(named: String(text[fromRange])),
              let target = unit(named: String(text[toRange])),
              source.kind == target.kind,
              let value = try? MathExpression.evaluate(String(text[valueRange])).value
        else { return nil }
        return UnitConversion(value: value, source: source, target: target)
    }

    func evaluate() -> Double? {
        guard source.kind == .temperature else { return value * source.factor / target.factor }
        let celsius: Double
        switch source.symbol {
        case "°F": celsius = (value - 32) * 5 / 9
        case "K": celsius = value - 273.15
        default: celsius = value
        }
        switch target.symbol {
        case "°F": return celsius * 9 / 5 + 32
        case "K": return celsius + 273.15
        default: return celsius
        }
    }

    private static func unit(named name: String) -> Unit? {
        let key = name.lowercased()
        // 先区分大小写（Mb 与 MB、m 与 M），再忽略大小写
        return units.first { $0.aliases.contains(name) } ?? units.first { $0.aliases.contains(key) }
    }

    private static let units: [Unit] = [
        // 长度，基准：米
        Unit(kind: .length, symbol: "mm", factor: 0.001, aliases: ["mm", "毫米", "millimeter", "millimeters"]),
        Unit(kind: .length, symbol: "cm", factor: 0.01, aliases: ["cm", "厘米", "centimeter", "centimeters"]),
        Unit(kind: .length, symbol: "m", factor: 1, aliases: ["m", "米", "meter", "meters", "metre", "metres"]),
        Unit(kind: .length, symbol: "km", factor: 1000, aliases: ["km", "千米", "公里", "kilometer", "kilometers"]),
        Unit(kind: .length, symbol: "in", factor: 0.0254, aliases: ["in", "inch", "inches", "英寸", "寸"]),
        Unit(kind: .length, symbol: "ft", factor: 0.3048, aliases: ["ft", "foot", "feet", "英尺"]),
        Unit(kind: .length, symbol: "yd", factor: 0.9144, aliases: ["yd", "yard", "yards", "码"]),
        Unit(kind: .length, symbol: "mi", factor: 1609.344, aliases: ["mi", "mile", "miles", "英里"]),
        Unit(kind: .length, symbol: "nmi", factor: 1852, aliases: ["nmi", "海里"]),
        Unit(kind: .length, symbol: "里", factor: 500, aliases: ["里"]),
        // 质量，基准：克
        Unit(kind: .mass, symbol: "mg", factor: 0.001, aliases: ["mg", "毫克"]),
        Unit(kind: .mass, symbol: "g", factor: 1, aliases: ["g", "克", "gram", "grams"]),
        Unit(kind: .mass, symbol: "kg", factor: 1000, aliases: ["kg", "千克", "公斤", "kilogram", "kilograms"]),
        Unit(kind: .mass, symbol: "t", factor: 1_000_000, aliases: ["t", "吨", "ton", "tons", "tonne"]),
        Unit(kind: .mass, symbol: "lb", factor: 453.59237, aliases: ["lb", "lbs", "pound", "pounds", "磅"]),
        Unit(kind: .mass, symbol: "oz", factor: 28.349523125, aliases: ["oz", "ounce", "ounces", "盎司"]),
        Unit(kind: .mass, symbol: "斤", factor: 500, aliases: ["斤", "jin"]),
        Unit(kind: .mass, symbol: "两", factor: 50, aliases: ["两"]),
        // 温度
        Unit(kind: .temperature, symbol: "°C", factor: 1, aliases: ["c", "°c", "℃", "celsius", "摄氏度", "摄氏"]),
        Unit(kind: .temperature, symbol: "°F", factor: 1, aliases: ["f", "°f", "℉", "fahrenheit", "华氏度", "华氏"]),
        Unit(kind: .temperature, symbol: "K", factor: 1, aliases: ["k", "kelvin", "开尔文"]),
        // 数据，基准：字节；KB/MB 按 1000（和访达一致），KiB/MiB 按 1024
        Unit(kind: .data, symbol: "bit", factor: 0.125, aliases: ["bit", "bits", "比特"]),
        Unit(kind: .data, symbol: "B", factor: 1, aliases: ["B", "byte", "bytes", "字节"]),
        Unit(kind: .data, symbol: "KB", factor: 1e3, aliases: ["KB", "kb", "千字节"]),
        Unit(kind: .data, symbol: "MB", factor: 1e6, aliases: ["MB", "mb", "兆", "兆字节"]),
        Unit(kind: .data, symbol: "GB", factor: 1e9, aliases: ["GB", "gb", "g字节"]),
        Unit(kind: .data, symbol: "TB", factor: 1e12, aliases: ["TB", "tb"]),
        Unit(kind: .data, symbol: "KiB", factor: 1024, aliases: ["kib"]),
        Unit(kind: .data, symbol: "MiB", factor: 1_048_576, aliases: ["mib"]),
        Unit(kind: .data, symbol: "GiB", factor: 1_073_741_824, aliases: ["gib"]),
        Unit(kind: .data, symbol: "TiB", factor: 1_099_511_627_776, aliases: ["tib"]),
        // 时间，基准：秒
        Unit(kind: .time, symbol: "ms", factor: 0.001, aliases: ["ms", "毫秒", "millisecond", "milliseconds"]),
        Unit(kind: .time, symbol: "s", factor: 1, aliases: ["s", "sec", "secs", "second", "seconds", "秒"]),
        Unit(kind: .time, symbol: "min", factor: 60, aliases: ["min", "mins", "minute", "minutes", "分钟", "分"]),
        Unit(kind: .time, symbol: "h", factor: 3600, aliases: ["h", "hr", "hrs", "hour", "hours", "小时", "时"]),
        Unit(kind: .time, symbol: "d", factor: 86400, aliases: ["d", "day", "days", "天", "日"]),
        Unit(kind: .time, symbol: "wk", factor: 604_800, aliases: ["wk", "week", "weeks", "周", "星期"]),
        Unit(kind: .time, symbol: "yr", factor: 31_536_000, aliases: ["yr", "year", "years", "年"]),
        // 体积，基准：升
        Unit(kind: .volume, symbol: "ml", factor: 0.001, aliases: ["ml", "毫升"]),
        Unit(kind: .volume, symbol: "L", factor: 1, aliases: ["l", "liter", "liters", "litre", "升"]),
        Unit(kind: .volume, symbol: "gal", factor: 3.785411784, aliases: ["gal", "gallon", "gallons", "加仑"]),
        Unit(kind: .volume, symbol: "fl oz", factor: 0.0295735295625, aliases: ["floz"]),
        Unit(kind: .volume, symbol: "cup", factor: 0.2365882365, aliases: ["cup", "cups", "杯"]),
        // 速度，基准：米/秒
        Unit(kind: .speed, symbol: "m/s", factor: 1, aliases: ["m/s", "mps", "米每秒"]),
        Unit(kind: .speed, symbol: "km/h", factor: 1 / 3.6, aliases: ["km/h", "kmh", "kph", "公里每小时"]),
        Unit(kind: .speed, symbol: "mph", factor: 0.44704, aliases: ["mph", "英里每小时"]),
        Unit(kind: .speed, symbol: "kn", factor: 1852.0 / 3600, aliases: ["kn", "knot", "knots", "节"]),
        // 面积，基准：平方米
        Unit(kind: .area, symbol: "m²", factor: 1, aliases: ["m2", "m²", "平方米", "平米"]),
        Unit(kind: .area, symbol: "km²", factor: 1e6, aliases: ["km2", "km²", "平方公里", "平方千米"]),
        Unit(kind: .area, symbol: "ha", factor: 1e4, aliases: ["ha", "hectare", "公顷"]),
        Unit(kind: .area, symbol: "亩", factor: 10000.0 / 15, aliases: ["亩"]),
        Unit(kind: .area, symbol: "ft²", factor: 0.09290304, aliases: ["ft2", "ft²", "sqft", "平方英尺"]),
        Unit(kind: .area, symbol: "acre", factor: 4046.8564224, aliases: ["acre", "acres", "英亩"]),
    ]
}
