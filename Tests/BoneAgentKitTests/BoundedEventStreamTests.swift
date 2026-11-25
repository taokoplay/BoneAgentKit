import Foundation
import XCTest
@testable import BoneAgentKit

final class BoundedEventStreamTests: XCTestCase {
    private typealias IntStream = BoneBoundedEventStream<Int>
    private typealias StringStream = BoneBoundedEventStream<String>

    func testLimitsValidateWithoutArbitraryCaps() throws {
        let defaults = BoneEventBufferLimits()
        XCTAssertEqual(defaults.maximumEventCount, 256)
        XCTAssertEqual(defaults.maximumQueuedPayloadBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(defaults.maximumEventPayloadBytes, 8 * 1_024 * 1_024)
        for (count, bytes, event) in [(0, 1, 1), (-1, 1, 1), (1, 0, 1), (1, -1, 1),
                                      (1, 1, 0), (1, 1, -1), (1, 1, 2), (Int.min, 1, 1)] {
            XCTAssertThrowsError(try limits(count, bytes, event)) {
                XCTAssertEqual($0 as? BoneEventStreamError, .invalidLimits)
            }
        }
        let largest = try limits(Int.max, Int.max, Int.max)
        XCTAssertEqual(largest.maximumEventCount, Int.max)
        XCTAssertEqual(largest.maximumQueuedPayloadBytes, Int.max)
        XCTAssertEqual(largest.maximumEventPayloadBytes, Int.max)
    }

    func testEventCountBackpressureResumesWhenAnEventIsDequeued() async throws {
        let attempted = XCTestExpectation(description: "second send reached stream")
        let (stream, producer) = StringStream.makeStream(limits: try limits(1, 100, 100)) {
            if $0 == "second" { attempted.fulfill() }
            return $0.utf8.count
        }
        defer { producer.finish() }
        XCTAssertEqual(producer.offer("first"), .accepted)
        let (sender, sent) = perform { try await producer.send("second") }
        defer { sender.cancel() }
        await fulfillment(of: [attempted], timeout: 2)
        await assertSuspended(sent)
        assertSnapshot(stream.bufferSnapshot, count: 1, bytes: 5, peakCount: 1, peakBytes: 5)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "first")
        try await value(sent)
        assertSnapshot(stream.bufferSnapshot, count: 1, bytes: 6, peakCount: 1, peakBytes: 6)
        producer.finish()
        let second = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(second, "second")
        XCTAssertNil(end)
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 1, peakBytes: 6)
    }

    func testByteBackpressureKeepsSmallerSendBehindEarlierWaiter() async throws {
        let largeAttempt = XCTestExpectation(description: "large send reached stream")
        let smallAttempt = XCTestExpectation(description: "small send reached stream")
        let (stream, producer) = StringStream.makeStream(limits: try limits(10, 5, 5)) {
            if $0 == "def" { largeAttempt.fulfill() }
            if $0 == "z" { smallAttempt.fulfill() }
            return $0.utf8.count
        }
        defer { producer.finish() }
        XCTAssertEqual(producer.offer("abc"), .accepted)
        let (largeTask, large) = perform { try await producer.send("def") }
        defer { largeTask.cancel() }
        await fulfillment(of: [largeAttempt], timeout: 2)
        await assertSuspended(large)
        let (smallTask, small) = perform { try await producer.send("z") }
        defer { smallTask.cancel() }
        await fulfillment(of: [smallAttempt], timeout: 2)
        await assertSuspended(small)
        // Neither waiting payload is charged to the queue, even though z alone fits.
        assertSnapshot(stream.bufferSnapshot, count: 1, bytes: 3, peakCount: 1, peakBytes: 3)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "abc")
        try await value(large)
        try await value(small)
        assertSnapshot(stream.bufferSnapshot, count: 2, bytes: 4, peakCount: 2, peakBytes: 4)
        producer.finish()
        let second = try await iterator.next()
        let third = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(second, "def")
        XCTAssertEqual(third, "z")
        XCTAssertNil(end)
    }

    func testFIFOCompleteDeliveryAcrossManyQueueCompactions() async throws {
        let attempted = XCTestExpectation(description: "producer reached byte backpressure")
        let gate = BoundedTestGate()
        let (stream, producer) = IntStream.makeStream(limits: try limits(7, 10, 3)) {
            if $0 == 5 { attempted.fulfill() }
            return $0 % 3 + 1
        }
        let (sender, sent) = perform {
            for event in 0..<1_024 { try await producer.send(event) }
            producer.finish()
        }
        let (consumer, received) = perform {
            await gate.wait()
            var events: [Int] = []
            for try await event in stream { events.append(event) }
            return events
        }
        defer { sender.cancel(); consumer.cancel(); producer.finish() }
        await fulfillment(of: [attempted], timeout: 2)
        await assertSuspended(sent)
        XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 9)
        await gate.open()
        try await value(sent)
        let events = try await value(received)
        XCTAssertEqual(events, Array(0..<1_024))
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
        XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
        XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedEventCount, 7)
        XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedPayloadBytes, 10)
    }

    func testOversizedSendFailsWithoutTruncatingPayloadAccounting() async throws {
        let (stream, producer) = IntStream.makeStream(limits: try limits(3, 8, 4), payloadSize: { $0 })
        XCTAssertEqual(producer.offer(2), .accepted)
        do {
            try await producer.send(Int.max)
            XCTFail("Expected eventTooLarge")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .eventTooLarge) }
        assertSnapshot(stream.bufferSnapshot, count: 1, bytes: 2, peakCount: 1, peakBytes: 2)
        XCTAssertEqual(producer.offer(1), .terminated)
        var iterator = stream.makeAsyncIterator()
        let buffered = try await iterator.next()
        XCTAssertEqual(buffered, 2)
        do {
            _ = try await iterator.next()
            XCTFail("Expected the stream's eventTooLarge failure")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .eventTooLarge) }
        do {
            try await producer.send(1)
            XCTFail("A failed stream must keep its failure")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .eventTooLarge) }
    }

    func testCallbackOfferOverflowIsExplicitAndTerminalForCountAndBytes() async throws {
        for countLimited in [true, false] {
            let configuredLimits = try limits(countLimited ? 1 : 10, 4, 4)
            let (stream, producer) = IntStream.makeStream(limits: configuredLimits, payloadSize: { $0 })
            XCTAssertEqual(producer.offer(3), .accepted)
            XCTAssertEqual(producer.offer(countLimited ? 0 : 2), .failed(.bufferOverflow))
            XCTAssertEqual(producer.offer(0), .terminated)
            assertSnapshot(stream.bufferSnapshot, count: 1, bytes: 3, peakCount: 1, peakBytes: 3)
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, 3)
            do {
                _ = try await iterator.next()
                XCTFail("Overflow must be observable by the consumer")
            } catch { XCTAssertEqual(error as? BoneEventStreamError, .bufferOverflow) }
            do {
                try await producer.send(0)
                XCTFail("Overflow must remain the producer's error")
            } catch { XCTAssertEqual(error as? BoneEventStreamError, .bufferOverflow) }
        }
    }

    func testOfferOversizeAndNegativePayloadFailWithoutEnqueueing() async throws {
        for (size, expected) in [(5, BoneEventStreamError.eventTooLarge), (-1, .invalidPayloadSize),
                                 (Int.min, .invalidPayloadSize)] {
            let (stream, producer) = IntStream.makeStream(limits: try limits(2, 8, 4), payloadSize: { $0 })
            XCTAssertEqual(producer.offer(size), .failed(expected))
            XCTAssertEqual(producer.offer(0), .terminated)
            assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 0, peakBytes: 0)
            var iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("Expected payload validation failure")
            } catch { XCTAssertEqual(error as? BoneEventStreamError, expected) }
        }
    }

    func testNegativeSendFailsTheStream() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { $0 })
        do {
            try await producer.send(-1)
            XCTFail("Expected invalidPayloadSize")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .invalidPayloadSize) }
        XCTAssertEqual(producer.offer(1), .terminated)
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected invalidPayloadSize")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .invalidPayloadSize) }
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 0, peakBytes: 0)
    }

    func testIntMaxBudgetDoesNotOverflowAndZeroPayloadStillCountsAsEvent() async throws {
        let (stream, producer) = IntStream.makeStream(limits: try limits(2, Int.max, Int.max), payloadSize: { $0 })
        XCTAssertEqual(producer.offer(Int.max), .accepted)
        XCTAssertEqual(producer.offer(0), .accepted)
        assertSnapshot(stream.bufferSnapshot, count: 2, bytes: Int.max, peakCount: 2, peakBytes: Int.max)
        XCTAssertEqual(producer.offer(1), .failed(.bufferOverflow))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual(first, Int.max)
        XCTAssertEqual(second, 0)
        do {
            _ = try await iterator.next()
            XCTFail("Expected overflow after buffered values")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .bufferOverflow) }
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 2, peakBytes: Int.max)
    }

    func testCancellingHeadSendUnblocksNextSendWithoutCancellingStream() async throws {
        let headAttempt = XCTestExpectation(description: "head send reached stream")
        let tailAttempt = XCTestExpectation(description: "tail send reached stream")
        let (stream, producer) = IntStream.makeStream(limits: try limits(10, 5, 5)) {
            if $0 == 4 { headAttempt.fulfill() }
            if $0 == 1 { tailAttempt.fulfill() }
            return $0
        }
        defer { producer.finish() }
        XCTAssertEqual(producer.offer(3), .accepted)
        let (headTask, head) = perform { try await producer.send(4) }
        defer { headTask.cancel() }
        await fulfillment(of: [headAttempt], timeout: 2)
        await assertSuspended(head)
        let (tailTask, tail) = perform { try await producer.send(1) }
        defer { tailTask.cancel() }
        await fulfillment(of: [tailAttempt], timeout: 2)
        await assertSuspended(tail)
        headTask.cancel()
        await assertCancellation(head)
        try await value(tail)
        assertSnapshot(stream.bufferSnapshot, count: 2, bytes: 4, peakCount: 2, peakBytes: 4)
        producer.finish()
        var events: [Int] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events, [3, 1])
    }

    func testAlreadyCancelledSendDoesNotFailOrConsumeBudget() async throws {
        let gate = BoundedTestGate()
        let (stream, producer) = IntStream.makeStream(payloadSize: { $0 })
        let (task, result) = perform {
            await gate.wait()
            try await producer.send(1)
        }
        defer { task.cancel(); producer.finish() }
        task.cancel()
        await gate.open()
        await assertCancellation(result)
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 0, peakBytes: 0)
        XCTAssertEqual(producer.offer(2), .accepted)
        producer.finish()
        var events: [Int] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events, [2])
    }

    func testCancellingWaitingNextCancelsProducerAndWakesConsumer() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
        let terminations = BoundedTestRecorder<IntStream.Termination>()
        let notified = XCTestExpectation(description: "producer cancelled")
        producer.onTermination { reason in terminations.append(reason); notified.fulfill() }
        let iterator = stream.makeAsyncIterator()
        let (consumer, result) = perform {
            var iterator = iterator
            return try await iterator.next()
        }
        defer { consumer.cancel(); producer.finish() }
        await assertSuspended(result)
        consumer.cancel()
        await assertCancellation(result)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(terminations.values, [.cancelled])
        XCTAssertEqual(producer.offer(1), .terminated)
        do {
            try await producer.send(1)
            XCTFail("Consumer cancellation must wake/reject sends")
        } catch { XCTAssertTrue(error is CancellationError) }
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 0, peakBytes: 0)
    }

    func testEarlyBreakCancelsEvenWhenStreamIsRetainedAndWakesPendingSend() async throws {
        let firstAttempt = XCTestExpectation(description: "first waiter reached stream")
        let secondAttempt = XCTestExpectation(description: "second waiter reached stream")
        let (stream, producer) = IntStream.makeStream(limits: try limits(1, 1, 1)) {
            if $0 == 1 { firstAttempt.fulfill() }
            if $0 == 2 { secondAttempt.fulfill() }
            return 1
        }
        let terminations = BoundedTestRecorder<IntStream.Termination>()
        let notified = XCTestExpectation(description: "iterator released")
        producer.onTermination { reason in terminations.append(reason); notified.fulfill() }
        XCTAssertEqual(producer.offer(0), .accepted)
        let (firstTask, first) = perform { try await producer.send(1) }
        defer { firstTask.cancel(); producer.finish() }
        await fulfillment(of: [firstAttempt], timeout: 2)
        await assertSuspended(first)
        let (secondTask, second) = perform { try await producer.send(2) }
        defer { secondTask.cancel() }
        await fulfillment(of: [secondAttempt], timeout: 2)
        await assertSuspended(second)

        let firstValue = try await consumeFirstAndBreak(stream)
        XCTAssertEqual(firstValue, 0)
        try await value(first)
        await assertCancellation(second)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(terminations.values, [.cancelled])
        // This access keeps stream alive across the loop and proves only the lease cancels.
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 1, peakBytes: 1)
        XCTAssertEqual(producer.offer(3), .terminated)
    }

    func testReleasingUnconsumedStreamCancelsDespiteRetainedProducer() async throws {
        let attempted = XCTestExpectation(description: "waiting send reached stream")
        let (holder, producer) = makeHeldStream(limits: try limits(1, 1, 1)) {
            if $0 == 1 { attempted.fulfill() }
            return 1
        }
        let reasons = BoundedTestRecorder<IntStream.Termination>()
        let notified = XCTestExpectation(description: "unconsumed owner released")
        producer.onTermination { reasons.append($0); notified.fulfill() }
        XCTAssertEqual(producer.offer(0), .accepted)
        let (sender, result) = perform { try await producer.send(1) }
        defer { sender.cancel(); producer.finish() }
        await fulfillment(of: [attempted], timeout: 2)
        await assertSuspended(result)
        XCTAssertEqual(holder.stream?.bufferSnapshot.bufferedEventCount, 1)
        holder.stream = nil
        await fulfillment(of: [notified], timeout: 2)
        await assertCancellation(result)
        XCTAssertEqual(reasons.values, [.cancelled])
        XCTAssertEqual(producer.offer(2), .terminated)
    }

    func testIteratorCanOutliveStreamOwner() async throws {
        let (holder, producer) = makeHeldStream(limits: .init(), payloadSize: { _ in 1 })
        let reasons = BoundedTestRecorder<IntStream.Termination>()
        producer.onTermination { reasons.append($0) }
        var iterator = try XCTUnwrap(holder.stream).makeAsyncIterator()
        holder.stream = nil
        XCTAssertTrue(reasons.values.isEmpty)
        XCTAssertEqual(producer.offer(7), .accepted)
        let event = try await iterator.next()
        XCTAssertEqual(event, 7)
        producer.finish()
        let end = try await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(reasons.values, [.finished])
    }

    func testIteratorCopiesShareLifetimeUntilLastCopyIsReleased() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
        let reasons = BoundedTestRecorder<IntStream.Termination>()
        producer.onTermination { reasons.append($0) }
        try await useIteratorCopies(stream, producer: producer)
        XCTAssertEqual(reasons.values, [.cancelled])
        XCTAssertEqual(producer.offer(2), .terminated)
        producer.finish()
        XCTAssertEqual(reasons.values, [.cancelled])
        XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
    }

    func testNormalFinishPreservesQueueAndRejectsWaitingSends() async throws {
        try await checkFinishPreservesQueue(error: nil)
    }

    func testErrorFinishPreservesQueueAndOriginalErrorIdentity() async throws {
        try await checkFinishPreservesQueue(error: BoundedTestFailure())
    }

    func testFinishWakesWaitingNextWithEOFOrOriginalError() async throws {
        for failed in [false, true] {
            let failure = BoundedTestFailure()
            let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
            let iterator = stream.makeAsyncIterator()
            let (consumer, result) = perform {
                var iterator = iterator
                return try await iterator.next()
            }
            defer { consumer.cancel(); producer.finish() }
            await assertSuspended(result)
            producer.finish(throwing: failed ? failure : nil)
            if failed {
                do {
                    _ = try await value(result)
                    XCTFail("Expected original failure")
                } catch { XCTAssertTrue((error as? BoundedTestFailure) === failure) }
            } else {
                let end = try await value(result)
                XCTAssertNil(end)
            }
        }
    }

    func testTerminationHandlerLateRegistrationAndReentrancyNotifyOnlyOnce() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
        let reasons = BoundedTestRecorder<IntStream.Termination>()
        producer.finish(throwing: BoundedTestFailure())
        producer.onTermination { reason in
            reasons.append(reason)
            // Each call reacquires the state lock, exercising synchronous reentrancy.
            XCTAssertEqual(producer.offer(1), .terminated)
            XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
            producer.finish()
            producer.onTermination { reasons.append($0) }
        }
        producer.onTermination { reasons.append($0) }
        producer.finish()
        XCTAssertEqual(reasons.values, [.failed])
    }

    func testTerminationHandlerRegistrationRaceNotifiesExactlyOnce() async throws {
        for _ in 0..<40 {
            let gate = BoundedTestGate()
            let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
            let reasons = BoundedTestRecorder<IntStream.Termination>()
            let notified = XCTestExpectation(description: "termination delivered")
            let (registration, registered) = perform {
                await gate.wait()
                producer.onTermination { reason in
                    reasons.append(reason)
                    XCTAssertEqual(producer.offer(1), .terminated)
                    _ = stream.bufferSnapshot
                    notified.fulfill()
                }
            }
            let (finisher, finished) = perform {
                await gate.wait()
                producer.finish()
            }
            defer { registration.cancel(); finisher.cancel(); producer.finish() }
            await gate.open()
            try await value(registered)
            try await value(finished)
            await fulfillment(of: [notified], timeout: 2)
            producer.onTermination { reasons.append($0) }
            producer.finish(throwing: BoundedTestFailure())
            XCTAssertEqual(reasons.values, [.finished])
        }
    }

    func testDuplicateConsumerDoesNotPolluteOriginalConsumer() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
        var original = stream.makeAsyncIterator()
        var duplicate = stream.makeAsyncIterator()
        do {
            _ = try await duplicate.next()
            XCTFail("Expected multipleConsumers")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .multipleConsumers) }
        XCTAssertEqual(producer.offer(1), .accepted)
        producer.finish()
        let first = try await original.next()
        let end = try await original.next()
        XCTAssertEqual(first, 1)
        XCTAssertNil(end)
        var later = stream.makeAsyncIterator()
        do {
            _ = try await later.next()
            XCTFail("The stream permits only one iteration")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .multipleConsumers) }
    }

    func testConcurrentNextOnIteratorCopiesIsRejectedWithoutCancellingOriginal() async throws {
        let (stream, producer) = IntStream.makeStream(payloadSize: { _ in 1 })
        var iterator = stream.makeAsyncIterator()
        let copy = iterator
        let (consumer, result) = perform {
            var copy = copy
            return try await copy.next()
        }
        defer { consumer.cancel(); producer.finish() }
        await assertSuspended(result)
        do {
            _ = try await iterator.next()
            XCTFail("Concurrent next calls must be rejected")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .multipleConsumers) }
        XCTAssertEqual(producer.offer(9), .accepted)
        let event = try await value(result)
        XCTAssertEqual(event, 9)
        producer.finish()
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testConcurrentSendsAndCancellationDeliverEveryAcceptedValueWithoutHanging() async throws {
        let attempts = XCTestExpectation(description: "all concurrent sends attempted")
        attempts.expectedFulfillmentCount = 100
        let gate = BoundedTestGate()
        let (stream, producer) = IntStream.makeStream(limits: try limits(4, 4, 1)) {
            if $0 >= 0 { attempts.fulfill() }
            return 1
        }
        for value in -4..<0 { XCTAssertEqual(producer.offer(value), .accepted) }
        var senders: [(Task<Void, Never>, BoundedTestResult<Void>)] = []
        for event in 0..<100 {
            senders.append(perform {
                await gate.wait()
                try await producer.send(event)
            })
        }
        defer { for (task, _) in senders { task.cancel() }; producer.finish() }
        await gate.open()
        await fulfillment(of: [attempts], timeout: 2)
        for index in stride(from: 0, to: 100, by: 2) { senders[index].0.cancel() }
        for index in stride(from: 0, to: 100, by: 2) { await assertCancellation(senders[index].1) }
        assertSnapshot(stream.bufferSnapshot, count: 4, bytes: 4, peakCount: 4, peakBytes: 4)

        let (consumer, received) = perform {
            var values: [Int] = []
            for try await value in stream { values.append(value) }
            return values
        }
        defer { consumer.cancel() }
        for index in stride(from: 1, to: 100, by: 2) { try await value(senders[index].1) }
        producer.finish()
        let events = try await value(received)
        let expected = Array(-4..<0) + Array(stride(from: 1, to: 100, by: 2))
        XCTAssertEqual(events.count, expected.count)
        XCTAssertEqual(Set(events), Set(expected))
        XCTAssertEqual(Array(events.prefix(4)), Array(-4..<0))
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 4, peakBytes: 4)
    }

    func testCancellationRacingAdmissionMatchesSuccessfulSendsExactly() async throws {
        for _ in 0..<8 {
            let gate = BoundedTestGate()
            let (stream, producer) = IntStream.makeStream(limits: try limits(4, 7, 3)) { $0 % 3 + 1 }
            var senders: [(Task<Void, Never>, BoundedTestResult<Void>)] = []
            for event in 0..<64 {
                senders.append(perform {
                    await gate.wait()
                    try await producer.send(event)
                })
            }
            let cancellationTargets = stride(from: 0, to: 64, by: 2).map { senders[$0].0 }
            let (consumer, received) = perform {
                await gate.wait()
                var values: [Int] = []
                for try await event in stream {
                    values.append(event)
                    await Task.yield()
                }
                return values
            }
            let (canceller, cancelled) = perform {
                await gate.wait()
                for task in cancellationTargets {
                    task.cancel()
                    await Task.yield()
                }
            }
            defer {
                for (task, _) in senders { task.cancel() }
                consumer.cancel()
                canceller.cancel()
                producer.finish()
            }
            await gate.open()
            await fulfillment(of: senders.map { $0.1.completed }, timeout: 2)
            try await value(cancelled)
            var accepted: [Int] = []
            for (index, sender) in senders.enumerated() {
                switch try XCTUnwrap(sender.1.value) {
                case .success:
                    accepted.append(index)
                case .failure(let error):
                    XCTAssertTrue(error is CancellationError)
                    XCTAssertEqual(index % 2, 0)
                }
            }
            producer.finish()
            let events = try await value(received)
            XCTAssertEqual(events.count, accepted.count)
            XCTAssertEqual(Set(events), Set(accepted))
            XCTAssertEqual(stream.bufferSnapshot.bufferedEventCount, 0)
            XCTAssertEqual(stream.bufferSnapshot.bufferedPayloadBytes, 0)
            XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedEventCount, 4)
            XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedPayloadBytes, 7)
        }
    }

    private func limits(_ count: Int, _ bytes: Int, _ event: Int) throws -> BoneEventBufferLimits {
        try BoneEventBufferLimits(maximumEventCount: count, maximumQueuedPayloadBytes: bytes,
                                  maximumEventPayloadBytes: event)
    }

    private func assertSnapshot(
        _ snapshot: BoneEventBufferSnapshot, count: Int, bytes: Int, peakCount: Int, peakBytes: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.bufferedEventCount, count, file: file, line: line)
        XCTAssertEqual(snapshot.bufferedPayloadBytes, bytes, file: file, line: line)
        XCTAssertEqual(snapshot.peakBufferedEventCount, peakCount, file: file, line: line)
        XCTAssertEqual(snapshot.peakBufferedPayloadBytes, peakBytes, file: file, line: line)
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> (Task<Void, Never>, BoundedTestResult<Value>) {
        let result = BoundedTestResult<Value>()
        let task = Task {
            do { result.complete(.success(try await operation())) }
            catch { result.complete(.failure(error)) }
        }
        return (task, result)
    }

    private func value<Value: Sendable>(
        _ result: BoundedTestResult<Value>, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Value {
        // Never await task.value after a timeout: a regression must fail, not hang the suite.
        await fulfillment(of: [result.completed], timeout: 2)
        return try XCTUnwrap(result.value, "Operation did not resume", file: file, line: line).get()
    }

    private func assertCancellation<Value: Sendable>(
        _ result: BoundedTestResult<Value>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await value(result, file: file, line: line)
            XCTFail("Expected cancellation", file: file, line: line)
        } catch { XCTAssertTrue(error is CancellationError, "Received \(error)", file: file, line: line) }
    }

    private func assertSuspended<Value: Sendable>(_ result: BoundedTestResult<Value>) async {
        let premature = XCTestExpectation(description: "operation must remain suspended")
        premature.isInverted = true
        result.observePrematureCompletion(premature)
        await fulfillment(of: [premature], timeout: 0.02)
        result.stopObservingPrematureCompletion()
    }

    private func consumeFirstAndBreak(_ stream: IntStream) async throws -> Int? {
        var first: Int?
        for try await event in stream {
            first = event
            break
        }
        return first
    }

    private func useIteratorCopies(_ stream: IntStream, producer: IntStream.Producer) async throws {
        var first: IntStream.AsyncIterator? = stream.makeAsyncIterator()
        var second = try XCTUnwrap(first)
        first = nil
        XCTAssertEqual(producer.offer(1), .accepted)
        let event = try await second.next()
        XCTAssertEqual(event, 1)
        withExtendedLifetime(second) {}
    }

    private func makeHeldStream(
        limits: BoneEventBufferLimits, payloadSize: @escaping @Sendable (Int) -> Int
    ) -> (BoundedTestStreamHolder, IntStream.Producer) {
        let (stream, producer) = IntStream.makeStream(limits: limits, payloadSize: payloadSize)
        return (BoundedTestStreamHolder(stream), producer)
    }

    private func checkFinishPreservesQueue(error failure: BoundedTestFailure?) async throws {
        let attempted = XCTestExpectation(description: "waiting send reached stream")
        let (stream, producer) = IntStream.makeStream(limits: try limits(2, 2, 1)) {
            if $0 == 3 { attempted.fulfill() }
            return 1
        }
        let reasons = BoundedTestRecorder<IntStream.Termination>()
        producer.onTermination { reasons.append($0) }
        XCTAssertEqual(producer.offer(1), .accepted)
        XCTAssertEqual(producer.offer(2), .accepted)
        let (sender, sent) = perform { try await producer.send(3) }
        defer { sender.cancel(); producer.finish() }
        await fulfillment(of: [attempted], timeout: 2)
        await assertSuspended(sent)
        producer.finish(throwing: failure)
        producer.finish(throwing: BoundedTestFailure())
        do {
            try await value(sent)
            XCTFail("Finish must reject sends that have not been admitted")
        } catch {
            if let failure { XCTAssertTrue((error as? BoundedTestFailure) === failure) }
            else { XCTAssertEqual(error as? BoneEventStreamError, .terminated) }
        }
        assertSnapshot(stream.bufferSnapshot, count: 2, bytes: 2, peakCount: 2, peakBytes: 2)
        XCTAssertEqual(producer.offer(4), .terminated)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        if let failure {
            do {
                _ = try await iterator.next()
                XCTFail("Expected original error after draining")
            } catch { XCTAssertTrue((error as? BoundedTestFailure) === failure) }
        } else {
            let end = try await iterator.next()
            XCTAssertNil(end)
        }
        do {
            try await producer.send(5)
            XCTFail("Finished producer must reject later sends")
        } catch {
            if let failure { XCTAssertTrue((error as? BoundedTestFailure) === failure) }
            else { XCTAssertEqual(error as? BoneEventStreamError, .terminated) }
        }
        XCTAssertEqual(reasons.values, [failure == nil ? .finished : .failed])
        assertSnapshot(stream.bufferSnapshot, count: 0, bytes: 0, peakCount: 2, peakBytes: 2)
    }
}

private final class BoundedTestFailure: Error, @unchecked Sendable {}

private final class BoundedTestStreamHolder {
    var stream: BoneBoundedEventStream<Int>?
    init(_ stream: BoneBoundedEventStream<Int>) { self.stream = stream }
}

private actor BoundedTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let previous = waiters
        waiters = []
        for waiter in previous { waiter.resume() }
    }
}

private final class BoundedTestRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class BoundedTestResult<Value: Sendable>: @unchecked Sendable {
    let completed = XCTestExpectation(description: "operation completed")
    private let lock = NSLock()
    private var storage: Result<Value, Error>?
    private var premature: XCTestExpectation?

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        storage = result
        let unexpected = premature
        lock.unlock()
        unexpected?.fulfill()
        completed.fulfill()
    }

    func observePrematureCompletion(_ expectation: XCTestExpectation) {
        lock.lock()
        premature = expectation
        let alreadyCompleted = storage != nil
        lock.unlock()
        if alreadyCompleted { expectation.fulfill() }
    }

    func stopObservingPrematureCompletion() {
        lock.lock()
        premature = nil
        lock.unlock()
    }
}
