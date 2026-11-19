import Foundation
import BoneAgentKit

/// Stable failures that never contain supplied dates, time zone identifiers, or amounts.
public enum BoneDateTimeError: String, Error, Codable, Equatable, Sendable {
    case invalidArguments
    case invalidDate
    case invalidTimeZone
    case invalidAmount
    case unsupportedUnit
    case dateOutOfRange
}

/// Queries the Host clock and performs explicit time zone and calendar operations.
///
/// Input dates use `YYYY-MM-DDTHH:mm:ss[.SSS]Z` or an explicit `+/-HH:mm` offset;
/// fractional seconds may contain one to three digits. Output dates include milliseconds.
/// Only `now` reads the injected clock. Other actions require explicit input dates.
///
/// `add` uses a Gregorian Calendar in the requested (or frozen default) time zone.
/// Calendar days preserve local wall time across DST where possible, so a day can be
/// 23 or 25 elapsed hours. Foundation resolves nonexistent/repeated local times.
/// Month/year addition clamps to the destination month's last valid day; reversing
/// a clamped addition need not restore the original date (Jan 31 -> Feb 29 -> Jan 29).
/// `difference` is signed `otherDate - date`, using fixed 1/60/3600/86400-second units.
public struct BoneDateTimeTool<Context: BoneAgentToolContext>: BoneAgentTool {
    public static var maximumDateLength: Int { 29 }
    public static var maximumTimeZoneIDLength: Int { 128 }
    public static var maximumAmount: Int { 1_000_000 }

    public enum Action: String, Codable, CaseIterable, Sendable {
        case now, convert, add, difference
    }

    public enum Unit: String, Codable, CaseIterable, Sendable {
        case seconds, minutes, hours, days, weeks, months, years

        fileprivate var calendarComponent: Calendar.Component {
            switch self {
            case .seconds: return .second
            case .minutes: return .minute
            case .hours: return .hour
            case .days: return .day
            case .weeks: return .weekOfYear
            case .months: return .month
            case .years: return .year
            }
        }

        fileprivate var differenceSeconds: Double? {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3_600
            case .days: return 86_400
            default: return nil
            }
        }
    }

    public enum Direction: String, Codable, CaseIterable, Sendable {
        case add, subtract
    }

    public struct Input: Codable, Equatable, Sendable {
        public let action: Action
        public let date: String?
        public let otherDate: String?
        public let timeZoneID: String?
        public let unit: Unit?
        public let amount: Int?
        public let direction: Direction?

        public init(
            action: Action,
            date: String? = nil,
            otherDate: String? = nil,
            timeZoneID: String? = nil,
            unit: Unit? = nil,
            amount: Int? = nil,
            direction: Direction? = nil
        ) {
            self.action = action
            self.date = date
            self.otherDate = otherDate
            self.timeZoneID = timeZoneID
            self.unit = unit
            self.amount = amount
            self.direction = direction
        }

        public init(from decoder: Decoder) throws {
            do {
                guard try BoneLocalToolSupport.containsOnlyKeys(
                    decoder, allowed: ["action", "date", "otherDate", "timeZoneID", "unit", "amount", "direction"]
                ) else { throw BoneDateTimeError.invalidArguments }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                action = try container.decode(Action.self, forKey: .action)
                date = try BoneLocalToolSupport.decodeOptional(String.self, from: container, forKey: .date)
                otherDate = try BoneLocalToolSupport.decodeOptional(String.self, from: container, forKey: .otherDate)
                timeZoneID = try BoneLocalToolSupport.decodeOptional(String.self, from: container, forKey: .timeZoneID)
                unit = try BoneLocalToolSupport.decodeOptional(Unit.self, from: container, forKey: .unit)
                amount = try BoneLocalToolSupport.decodeOptional(Int.self, from: container, forKey: .amount)
                direction = try BoneLocalToolSupport.decodeOptional(Direction.self, from: container, forKey: .direction)
                try BoneDateTimeTool.validateInput(self)
            } catch let error as BoneDateTimeError {
                throw error
            } catch {
                throw BoneDateTimeError.invalidArguments
            }
        }

        private enum CodingKeys: String, CodingKey {
            case action, date, otherDate, timeZoneID, unit, amount, direction
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public let utcDate: String
        public let localDate: String
        public let epoch: Double
        public let timeZoneID: String
        /// Signed `otherDate - date` for `difference`; otherwise absent.
        public let difference: Double?
        public let unit: Unit?

        public init(
            utcDate: String,
            localDate: String,
            epoch: Double,
            timeZoneID: String,
            difference: Double? = nil,
            unit: Unit? = nil
        ) {
            self.utcDate = utcDate
            self.localDate = localDate
            self.epoch = epoch
            self.timeZoneID = timeZoneID
            self.difference = difference
            self.unit = unit
        }
    }

    private let clock: @Sendable () -> Date
    private let defaultTimeZone: TimeZone

    /// Captures the default time zone once. A Host may inject a deterministic clock.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        defaultTimeZone: TimeZone = .current
    ) {
        self.clock = clock
        // Snapshot an autoupdating TimeZone as well as TimeZone.current.
        self.defaultTimeZone = TimeZone(identifier: defaultTimeZone.identifier) ?? defaultTimeZone
    }

    public static var definition: BoneAgentToolDefinition {
        BoneAgentToolDefinition(
            id: "time.query",
            version: "1.0.0",
            title: "Date and time",
            summary: "now reads the Host clock; convert/add/difference require explicit ISO8601 dates "
                + "with seconds and Z or +/-HH:mm (optional 1-3 fractional digits). "
                + "timeZoneID is a Foundation time zone identifier; the Host default is used if omitted. "
                + "add requires nonnegative amount and direction, and uses Gregorian calendar units "
                + "in that zone (DST and month-end clamping apply). difference is otherDate minus date "
                + "in fixed seconds/minutes/hours/86400-second days. Outputs include UTC/local dates, "
                + "Unix epoch seconds and timeZoneID; difference also describes the first date. "
                + "Supported UTC years: 0001-9999; amount: 0-1000000.",
            wireName: "time_query",
            schemaVersion: 1,
            inputSchema: .taggedUnion(discriminator: "action", variants: Action.allCases.map(schema)),
            executionPolicy: .serial,
            impact: BoneLocalToolSupport.impact
        )
    }

    public func execute(input: Input, context: Context) async throws -> Output {
        try Task.checkCancellation()
        try Self.validateInput(input)
        let timeZone: TimeZone
        if let identifier = input.timeZoneID {
            guard let requested = TimeZone(identifier: identifier) else { throw BoneDateTimeError.invalidTimeZone }
            timeZone = requested
        } else {
            timeZone = defaultTimeZone
        }

        let result: Date
        var difference: Double?
        switch input.action {
        case .now:
            result = clock()
        case .convert:
            guard let date = input.date else { throw BoneDateTimeError.invalidArguments }
            result = try Self.parse(date)
        case .add:
            guard let date = input.date, let unit = input.unit,
                  let amount = input.amount, let direction = input.direction else {
                throw BoneDateTimeError.invalidArguments
            }
            let base = try Self.parse(date)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = timeZone
            // The bounded nonnegative amount makes negation safe, including decoded input.
            let signedAmount = direction == .add ? amount : -amount
            guard let adjusted = calendar.date(
                byAdding: unit.calendarComponent, value: signedAmount, to: base, wrappingComponents: false
            ) else { throw BoneDateTimeError.dateOutOfRange }
            result = adjusted
        case .difference:
            guard let date = input.date, let otherDate = input.otherDate,
                  let unit = input.unit, let seconds = unit.differenceSeconds else {
                throw BoneDateTimeError.invalidArguments
            }
            result = try Self.parse(date)
            difference = try Self.parse(otherDate).timeIntervalSince(result) / seconds
        }
        try Self.validateRange(result)
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.era, .year], from: result)
        guard components.era == 1, let year = components.year, (1...9_999).contains(year) else {
            throw BoneDateTimeError.dateOutOfRange
        }
        let utcDate = Self.format(result, timeZone: TimeZone(secondsFromGMT: 0)!)
        let localDate = Self.format(result, timeZone: timeZone)
        try Task.checkCancellation()
        return Output(
            utcDate: utcDate, localDate: localDate, epoch: result.timeIntervalSince1970,
            timeZoneID: timeZone.identifier, difference: difference, unit: input.unit
        )
    }

    private static func schema(_ action: Action) -> BoneToolSchema {
        var properties: [String: BoneToolSchema] = [
            "action": .string(enumValues: [action.rawValue], minimumLength: 1, maximumLength: 10),
            "timeZoneID": .string(enumValues: [], minimumLength: 1, maximumLength: maximumTimeZoneIDLength)
        ]
        var required = ["action"]
        if action != .now {
            properties["date"] = .string(enumValues: [], minimumLength: 20, maximumLength: maximumDateLength)
            required.append("date")
        }
        if action == .difference {
            properties["otherDate"] = .string(enumValues: [], minimumLength: 20, maximumLength: maximumDateLength)
            required.append("otherDate")
        }
        if action == .add || action == .difference {
            let units = action == .difference
                ? Unit.allCases.filter { $0.differenceSeconds != nil } : Unit.allCases
            properties["unit"] = .string(enumValues: units.map(\.rawValue), minimumLength: 1, maximumLength: 7)
            required.append("unit")
        }
        if action == .add {
            properties["amount"] = .integer(minimum: 0, maximum: maximumAmount)
            properties["direction"] = .string(
                enumValues: Direction.allCases.map(\.rawValue), minimumLength: 1, maximumLength: 8
            )
            required += ["amount", "direction"]
        }
        return .object(properties: properties, required: required, additionalProperties: false)
    }

    private static func validateInput(_ input: Input) throws {
        for date in [input.date, input.otherDate].compactMap({ $0 }) {
            let length = date.utf8.prefix(maximumDateLength + 1).count
            guard (20...maximumDateLength).contains(length) else { throw BoneDateTimeError.invalidDate }
        }
        if let identifier = input.timeZoneID {
            let length = identifier.utf8.prefix(maximumTimeZoneIDLength + 1).count
            guard (1...maximumTimeZoneIDLength).contains(length) else { throw BoneDateTimeError.invalidTimeZone }
        }
        if let amount = input.amount, !(0...maximumAmount).contains(amount) {
            throw BoneDateTimeError.invalidAmount
        }
        switch input.action {
        case .now:
            guard input.date == nil, input.otherDate == nil, input.unit == nil,
                  input.amount == nil, input.direction == nil else { throw BoneDateTimeError.invalidArguments }
        case .convert:
            guard input.date != nil, input.otherDate == nil, input.unit == nil,
                  input.amount == nil, input.direction == nil else { throw BoneDateTimeError.invalidArguments }
        case .add:
            guard input.date != nil, input.otherDate == nil, input.unit != nil,
                  input.amount != nil, input.direction != nil else { throw BoneDateTimeError.invalidArguments }
        case .difference:
            guard input.date != nil, input.otherDate != nil, let unit = input.unit,
                  input.amount == nil, input.direction == nil else { throw BoneDateTimeError.invalidArguments }
            guard unit.differenceSeconds != nil else { throw BoneDateTimeError.unsupportedUnit }
        }
    }

    /// Checks the entire ASCII representation before Foundation parsing, which can be permissive.
    private static func parse(_ text: String) throws -> Date {
        let bytes = Array(text.utf8)
        guard (20...maximumDateLength).contains(bytes.count),
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { throw BoneDateTimeError.invalidDate }
        func number(_ start: Int, _ length: Int) throws -> Int {
            var value = 0
            for index in start..<(start + length) {
                guard (48...57).contains(bytes[index]) else { throw BoneDateTimeError.invalidDate }
                value = value * 10 + Int(bytes[index] - 48)
            }
            return value
        }
        let year = try number(0, 4)
        let month = try number(5, 2)
        let day = try number(8, 2)
        let hour = try number(11, 2)
        let minute = try number(14, 2)
        let second = try number(17, 2)
        guard (1...9_999).contains(year), (1...12).contains(month),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw BoneDateTimeError.invalidDate
        }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { throw BoneDateTimeError.invalidDate }
        var index = 19
        let hasFraction = bytes[index] == 46
        if hasFraction {
            index += 1
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard (1...3).contains(index - start) else { throw BoneDateTimeError.invalidDate }
        }
        guard index < bytes.count else { throw BoneDateTimeError.invalidDate }
        if bytes[index] == 90 {
            guard index + 1 == bytes.count else { throw BoneDateTimeError.invalidDate }
        } else {
            guard bytes[index] == 43 || bytes[index] == 45,
                  index + 6 == bytes.count, bytes[index + 3] == 58,
                  try number(index + 1, 2) <= 23,
                  try number(index + 4, 2) <= 59 else { throw BoneDateTimeError.invalidDate }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw BoneDateTimeError.invalidDate }
        try validateRange(date)
        return date
    }

    private static func validateRange(_ date: Date) throws {
        let epoch = date.timeIntervalSince1970
        // Bound before asking Foundation Calendar to inspect an arbitrary Host clock value.
        guard epoch.isFinite, epoch >= -62_135_596_800, epoch < 253_402_300_800 else {
            throw BoneDateTimeError.dateOutOfRange
        }
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
