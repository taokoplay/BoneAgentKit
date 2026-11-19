import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools

private typealias Calculator = BoneCalculatorTool<BoneAgentEmptyContext>
private typealias DateTime = BoneDateTimeTool<BoneAgentEmptyContext>

@Suite("Local calculator and date/time tools")
struct LocalToolsTests {
    @Test func definitionsAreCompleteSerialAndHaveNoImpact() throws {
        for definition in [Calculator.definition, DateTime.definition] {
            #expect(try definition.validatedForModelExposure() == definition)
            #expect(definition.executionPolicy == .serial)
            let impact = try definition.requiredImpact()
            #expect(impact.dataAccess == .none)
            #expect(impact.externalTransmission == .none)
            #expect(impact.stateChange == .none)
            #expect(impact.economic == .none)
            #expect(impact.userVisible == .none)
            #expect(impact.permissionChange == .none)
        }
        #expect(Calculator.definition.id == "math.calculate")
        #expect(Calculator.definition.wireName == "math_calculate")
        #expect(DateTime.definition.id == "time.query")
        #expect(DateTime.definition.wireName == "time_query")
    }

    @Test func calculatorPrecedenceUnaryPowerAndNumericLiterals() async throws {
        let cases: [(String, Double)] = [
            ("2+3*4", 14), ("(2+3)*4", 20), ("-2^2", -4), ("(-2)^2", 4),
            ("2^3^2", 512), ("2^-2", 0.25), ("--3 + +2", 5), ("3*-2", -6),
            ("-5%2", -1), ("8/2*2", 8), (".5 + 1. + 1e-2", 1.51),
            ("\t1 +\n2\r", 3), ("0^0", 1)
        ]
        for (expression, expected) in cases {
            let result = try await calculate(expression)
            #expect(abs(result - expected) < 1e-12)
        }
    }

    @Test func calculatorFunctionsAndRounding() async throws {
        let cases: [(String, Double)] = [
            ("abs(-3)", 3), ("sqrt(81)", 9), ("min(3,2)", 2), ("max(-3,-2)", -2),
            ("round(2.5)", 3), ("round(-2.5)", -3), ("floor(-1.2)", -2),
            ("ceil(-1.2)", -1), ("percent(25)*200", 50),
            ("max(abs(-3),min(sqrt(81),round(4.5)))", 5)
        ]
        for (expression, expected) in cases {
            let result = try await calculate(expression)
            #expect(result == expected)
        }
    }

    @Test func calculatorRejectsMalformedTrailingAndExecutableInput() async {
        for expression in [
            "", " ", ".", "1e", "1e+", "1..2", "1 2", "2(3)", "(1", "1)", "1,2",
            "abs()", "min(1)", "max(1,2,3)", "round(1,2)", "ABS(1)", "sin(0)",
            "NaN", "Infinity", "1;system(\"id\")", "sqrt(4); 7", "$(id)", "1 // comment",
            "{1+2}", "[1]", "1=2", "1\u{0}", "１+２", "1\u{00a0}+2"
        ] {
            await expectCalculatorError(.invalidExpression, expression: expression)
        }
    }

    @Test func calculatorRejectsDomainDivisionAndNonfiniteResults() async {
        for expression in ["1/0", "1/-0", "5%0", "0^-1"] {
            await expectCalculatorError(.divisionByZero, expression: expression)
        }
        for expression in ["sqrt(-1)", "(-2)^0.5"] {
            await expectCalculatorError(.domainError, expression: expression)
        }
        for expression in ["1e309", "1e308*10", "10^1000"] {
            await expectCalculatorError(.nonFiniteResult, expression: expression)
        }
    }

    @Test func calculatorEnforcesIndependentResourceLimits() async throws {
        let padded = "1" + String(repeating: " ", count: Calculator.maximumExpressionBytes - 1)
        #expect(try await calculate(padded) == 1)
        await expectCalculatorError(.expressionTooLong, expression: padded + " ")
        await expectCalculatorError(.expressionTooLong, expression: String(repeating: "é", count: 2_049))

        let parentheses = String(repeating: "(", count: Calculator.maximumNestingDepth)
            + "1" + String(repeating: ")", count: Calculator.maximumNestingDepth)
        #expect(try await calculate(parentheses) == 1)
        await expectCalculatorError(.depthLimitExceeded, expression: "(" + parentheses + ")")
        #expect(try await calculate(String(repeating: "-", count: 64) + "1") == 1)
        await expectCalculatorError(.depthLimitExceeded, expression: String(repeating: "-", count: 65) + "1")
        await expectCalculatorError(
            .depthLimitExceeded, expression: Array(repeating: "1", count: 66).joined(separator: "^")
        )
        await expectCalculatorError(
            .depthLimitExceeded,
            expression: String(repeating: "abs(", count: 65) + "1" + String(repeating: ")", count: 65)
        )

        let operations = Array(repeating: "1", count: Calculator.maximumOperationCount + 1).joined(separator: "+")
        #expect(try await calculate(operations) == 129)
        await expectCalculatorError(.operationLimitExceeded, expression: operations + "+1")

        // 512 tokens and 128 operations: the token boundary is reachable with shallow nesting.
        let tokens = "(+1)+" + Array(repeating: "(1)", count: 127).joined(separator: "+")
        #expect(try await calculate(tokens) == 128)
        await expectCalculatorError(
            .tokenLimitExceeded, expression: String(repeating: "+", count: Calculator.maximumTokenCount + 1)
        )
    }

    @Test func calculatorDecodingRejectsMissingUnknownNullAndOversizedValues() throws {
        let decoder = JSONDecoder()
        for json in ["{}", "[]", "null", "{\"expression\":null}", "{\"expression\":2}",
                     "{\"expression\":\"1\",\"unexpected\":true}"] {
            #expect(throws: BoneCalculatorError.invalidArguments) {
                try decoder.decode(Calculator.Input.self, from: Data(json.utf8))
            }
        }
        #expect(throws: BoneCalculatorError.invalidExpression) {
            try decoder.decode(Calculator.Input.self, from: Data("{\"expression\":\"\"}".utf8))
        }
        let oversized = try JSONEncoder().encode(Calculator.Input(expression: String(repeating: "1", count: 4_097)))
        #expect(throws: BoneCalculatorError.expressionTooLong) {
            try decoder.decode(Calculator.Input.self, from: oversized)
        }
        try roundTrip(Calculator.Input(expression: "sqrt(4)"))
        try roundTrip(Calculator.Output(value: 2))
    }

    @Test func nowUsesHostClockAndFrozenDefaultOrExplicitZone() async throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let tool = DateTime(clock: { Date(timeIntervalSince1970: 0) }, defaultTimeZone: timeZone)
        let result = try await tool.execute(input: .init(action: .now), context: BoneAgentEmptyContext())
        #expect(result.utcDate == "1970-01-01T00:00:00.000Z")
        #expect(result.localDate == "1970-01-01T09:00:00.000+09:00")
        #expect(result.epoch == 0)
        #expect(result.timeZoneID == "Asia/Tokyo")
        #expect(result.difference == nil)
        let utc = try await tool.execute(
            input: .init(action: .now, timeZoneID: "UTC"), context: BoneAgentEmptyContext()
        )
        #expect(utc.localDate == utc.utcDate)
        #expect(utc.timeZoneID == "GMT" || utc.timeZoneID == "UTC")
    }

    @Test func explicitDatesDoNotReadClockAndOffsetsAndFractionsArePreserved() async throws {
        let tool = DateTime(clock: { Date(timeIntervalSince1970: .infinity) }, defaultTimeZone: utcZone)
        for (fraction, suffix, epoch): (String, String, Double) in [
            ("", "000", 0), (".1", "100", 0.1), (".12", "120", 0.12), (".125", "125", 0.125)
        ] {
            let result = try await tool.execute(
                input: .init(action: .convert, date: "1970-01-01T05:45:00\(fraction)+05:45", timeZoneID: "Asia/Tokyo"),
                context: BoneAgentEmptyContext()
            )
            #expect(result.utcDate == "1970-01-01T00:00:00.\(suffix)Z")
            #expect(result.localDate == "1970-01-01T09:00:00.\(suffix)+09:00")
            #expect(abs(result.epoch - epoch) < 1e-6)
        }
        let negativeOffset = try await query(.init(action: .convert, date: "1969-12-31T19:00:00-05:00"))
        #expect(negativeOffset.epoch == 0)
    }

    @Test func dateParsingRequiresAnExplicitZoneAndRejectsRolloverAndTrailingContent() async {
        for date in [
            "2024-02-29", "2024-02-29T12:00:00", "2024-02-29 12:00:00Z", "2024-02-29t12:00:00z",
            "2023-02-29T12:00:00Z", "2024-02-30T12:00:00Z", "2024-04-31T12:00:00Z",
            "0000-01-01T00:00:00Z", "2024-01-01T24:00:00Z", "2024-01-01T00:60:00Z",
            "2024-01-01T00:00:60Z", "2024-01-01T00:00:00+24:00", "2024-01-01T00:00:00+01:60",
            "2024-01-01T00:00:00Zjunk", "2024-01-01T00:00:00Z\n", "2024-01-01T00:00:00Z\u{0}",
            "2024-01-01T00:00:00.Z", "2024-01-01T00:00:00.1234Z", "2024-01-01T00:00:00+0800"
        ] {
            await expectDateTimeError(.invalidDate, input: .init(action: .convert, date: date))
        }
    }

    @Test func dateTimeRejectsInvalidZonesAndUnboundedHostClock() async {
        for zone in ["", "Mars/Olympus_Mons", String(repeating: "x", count: 129)] {
            await expectDateTimeError(.invalidTimeZone, input: .init(action: .now, timeZoneID: zone))
        }
        for epoch in [Double.infinity, -.infinity, .nan, 253_402_300_800, -62_135_596_801] {
            let tool = DateTime(clock: { Date(timeIntervalSince1970: epoch) }, defaultTimeZone: utcZone)
            do {
                _ = try await tool.execute(input: .init(action: .now), context: BoneAgentEmptyContext())
                Issue.record("Expected a bounded clock failure")
            } catch {
                #expect(error as? BoneDateTimeError == .dateOutOfRange)
            }
        }
    }

    @Test func calendarDayAdditionCrossesSpringAndFallDST() async throws {
        let cases: [(String, String, Double)] = [
            ("2024-03-09T12:00:00-05:00", "2024-03-10T12:00:00.000-04:00", 23),
            ("2024-11-02T12:00:00-04:00", "2024-11-03T12:00:00.000-05:00", 25)
        ]
        for (date, expected, elapsedHours) in cases {
            let result = try await query(.init(
                action: .add, date: date, timeZoneID: "America/New_York", unit: .days, amount: 1, direction: .add
            ))
            let base = try await query(.init(action: .convert, date: date))
            #expect(result.localDate == expected)
            #expect(result.epoch - base.epoch == elapsedHours * 3_600)
        }
        let hours = try await query(.init(
            action: .add, date: "2024-03-09T12:00:00-05:00", timeZoneID: "America/New_York",
            unit: .hours, amount: 24, direction: .add
        ))
        #expect(hours.localDate == "2024-03-10T13:00:00.000-04:00")
    }

    @Test func calendarMonthEndLeapYearSubtractionAndZero() async throws {
        let month = try await query(.init(
            action: .add, date: "2024-01-31T12:00:00Z", unit: .months, amount: 1, direction: .add
        ))
        #expect(month.utcDate == "2024-02-29T12:00:00.000Z")
        let reverse = try await query(.init(
            action: .add, date: month.utcDate, unit: .months, amount: 1, direction: .subtract
        ))
        #expect(reverse.utcDate == "2024-01-29T12:00:00.000Z")
        let year = try await query(.init(
            action: .add, date: month.utcDate, unit: .years, amount: 1, direction: .add
        ))
        #expect(year.utcDate == "2025-02-28T12:00:00.000Z")
        let zero = try await query(.init(
            action: .add, date: month.utcDate, unit: .seconds, amount: 0, direction: .subtract
        ))
        #expect(zero.utcDate == month.utcDate)
        await expectDateTimeError(.dateOutOfRange, input: .init(
            action: .add, date: "9999-12-31T12:00:00Z", unit: .years, amount: 1, direction: .add
        ))
    }

    @Test func differencesAreSignedFixedUnitsIncludingDSTAndRepeatedHours() async throws {
        let cases: [(DateTime.Unit, Double)] = [(.seconds, 82_800), (.minutes, 1_380), (.hours, 23), (.days, 23.0 / 24)]
        for (unit, expected) in cases {
            let result = try await query(.init(
                action: .difference, date: "2024-03-09T12:00:00-05:00", otherDate: "2024-03-10T12:00:00-04:00",
                timeZoneID: "America/New_York", unit: unit
            ))
            let difference = try #require(result.difference)
            #expect(abs(difference - expected) < 1e-12)
            #expect(result.unit == unit)
            #expect(result.localDate == "2024-03-09T12:00:00.000-05:00")
        }
        let reversed = try await query(.init(
            action: .difference, date: "2024-03-10T12:00:00-04:00", otherDate: "2024-03-09T12:00:00-05:00",
            unit: .minutes
        ))
        #expect(reversed.difference == -1_380)
        let repeatedHour = try await query(.init(
            action: .difference, date: "2024-11-03T01:30:00-04:00", otherDate: "2024-11-03T01:30:00-05:00",
            unit: .hours
        ))
        #expect(repeatedHour.difference == 1)
        let fraction = try await query(.init(
            action: .difference, date: "1970-01-01T00:00:00Z", otherDate: "1970-01-01T00:00:00.125Z", unit: .seconds
        ))
        #expect(fraction.difference == 0.125)
        await expectDateTimeError(.unsupportedUnit, input: .init(
            action: .difference, date: "2024-01-01T00:00:00Z", otherDate: "2024-02-01T00:00:00Z", unit: .months
        ))
    }

    @Test func dateTimeValidatesDirectInputAndNonnegativeAmount() async {
        for amount in [-1, Int.min, Int.max, DateTime.maximumAmount + 1] {
            await expectDateTimeError(.invalidAmount, input: .init(
                action: .add, date: "2024-01-01T00:00:00Z", unit: .seconds, amount: amount, direction: .subtract
            ))
        }
        for input in [
            DateTime.Input(action: .now, date: "2024-01-01T00:00:00Z"), .init(action: .convert),
            .init(action: .convert, date: "2024-01-01T00:00:00Z", amount: 1),
            .init(action: .add, date: "2024-01-01T00:00:00Z", unit: .days, amount: 1),
            .init(action: .difference, date: "2024-01-01T00:00:00Z", unit: .seconds)
        ] {
            await expectDateTimeError(.invalidArguments, input: input)
        }
    }

    @Test func dateTimeDecodingHasStrictEnumsFieldsTypesAndActionRequirements() throws {
        let decoder = JSONDecoder()
        for json in [
            "{}", "[]", "null", "{\"action\":\"tomorrow\"}", "{\"action\":1}",
            "{\"action\":\"now\",\"unexpected\":true}", "{\"action\":\"now\",\"timeZoneID\":null}",
            "{\"action\":\"convert\"}", "{\"action\":\"convert\",\"date\":123}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"days\",\"amount\":1}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"days\",\"amount\":1.5,\"direction\":\"add\"}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"days\",\"amount\":true,\"direction\":\"add\"}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"days\",\"amount\":1e100,\"direction\":\"add\"}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"fortnights\",\"amount\":1,\"direction\":\"add\"}",
            "{\"action\":\"add\",\"date\":\"2024-01-01T00:00:00Z\",\"unit\":\"days\",\"amount\":1,\"direction\":\"backwards\"}"
        ] {
            #expect(throws: BoneDateTimeError.invalidArguments) {
                try decoder.decode(DateTime.Input.self, from: Data(json.utf8))
            }
        }
        let negative = DateTime.Input(
            action: .add, date: "2024-01-01T00:00:00Z", unit: .seconds, amount: Int.min, direction: .subtract
        )
        let data = try JSONEncoder().encode(negative)
        #expect(throws: BoneDateTimeError.invalidAmount) {
            try decoder.decode(DateTime.Input.self, from: data)
        }
    }

    @Test func schemasMatchValidInputsAndEnforceEveryActionRequiredField() throws {
        let calculatorSchema = try #require(Calculator.definition.validatedForModelExposure().inputSchema)
        try BoneToolSchemaValidator.validate(
            arguments: JSONEncoder().encode(Calculator.Input(expression: "2+2")), against: calculatorSchema
        )
        let schema = try #require(DateTime.definition.validatedForModelExposure().inputSchema)
        let cases: [(DateTime.Input, [String])] = [
            (.init(action: .now), ["action"]),
            (.init(action: .convert, date: "2024-01-01T00:00:00Z"), ["action", "date"]),
            (.init(action: .add, date: "2024-01-01T00:00:00Z", unit: .days, amount: 1, direction: .subtract),
             ["action", "date", "unit", "amount", "direction"]),
            (.init(action: .difference, date: "2024-01-01T00:00:00Z", otherDate: "2024-01-02T00:00:00Z", unit: .hours),
             ["action", "date", "otherDate", "unit"])
        ]
        for (input, required) in cases {
            let data = try JSONEncoder().encode(input)
            try BoneToolSchemaValidator.validate(arguments: data, against: schema)
            try roundTrip(input)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for key in required {
                var missing = object
                missing.removeValue(forKey: key)
                let invalid = try JSONSerialization.data(withJSONObject: missing)
                #expect(throws: BoneToolSchemaError.argumentsMismatch) {
                    try BoneToolSchemaValidator.validate(arguments: invalid, against: schema)
                }
            }
            var extra = object
            extra["extra"] = true
            let invalid = try JSONSerialization.data(withJSONObject: extra)
            #expect(throws: BoneToolSchemaError.argumentsMismatch) {
                try BoneToolSchemaValidator.validate(arguments: invalid, against: schema)
            }
        }
        try roundTrip(DateTime.Output(
            utcDate: "1970-01-01T00:00:00.000Z", localDate: "1970-01-01T00:00:00.000Z",
            epoch: 0, timeZoneID: "UTC", difference: -1, unit: .hours
        ))
    }

    @Test func bothToolsHonorCancellationBeforeDoingWork() async {
        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            var cancellations = 0
            do {
                _ = try await Calculator().execute(input: .init(expression: "1+2"), context: BoneAgentEmptyContext())
            } catch is CancellationError { cancellations += 1 } catch { Issue.record("Unexpected calculator failure") }
            let tool = DateTime(clock: {
                Issue.record("Cancelled time query read the clock")
                return Date(timeIntervalSince1970: 0)
            }, defaultTimeZone: utcZone)
            do {
                _ = try await tool.execute(input: .init(action: .now), context: BoneAgentEmptyContext())
            } catch is CancellationError { cancellations += 1 } catch { Issue.record("Unexpected date/time failure") }
            return cancellations
        }
        #expect(await task.value == 2)
    }
}

private var utcZone: TimeZone { TimeZone(secondsFromGMT: 0)! }

private func calculate(_ expression: String) async throws -> Double {
    try await Calculator().execute(input: .init(expression: expression), context: BoneAgentEmptyContext()).value
}

private func query(_ input: DateTime.Input) async throws -> DateTime.Output {
    try await DateTime(clock: { Date(timeIntervalSince1970: 0) }, defaultTimeZone: utcZone)
        .execute(input: input, context: BoneAgentEmptyContext())
}

private func expectCalculatorError(_ expected: BoneCalculatorError, expression: String) async {
    do {
        _ = try await calculate(expression)
        Issue.record("Expected a calculator failure")
    } catch {
        #expect(error as? BoneCalculatorError == expected)
    }
}

private func expectDateTimeError(_ expected: BoneDateTimeError, input: DateTime.Input) async {
    do {
        _ = try await query(input)
        Issue.record("Expected a date/time failure")
    } catch {
        #expect(error as? BoneDateTimeError == expected)
    }
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(Value.self, from: data) == value)
}
