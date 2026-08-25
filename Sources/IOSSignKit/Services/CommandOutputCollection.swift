import Foundation
import Darwin

final class CommandOutputCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let isError: Bool
    private let onOutput: (@Sendable (String, Bool) -> Void)?
    private let buffer: OutputBuffer
    private let decoder = IncrementalUTF8Decoder()
    private let finishGroup = DispatchGroup()
    private let finishLock = NSLock()
    private var didFinish = false
    private var forcedBeforeEndOfFile = false

    init(
        handle: FileHandle,
        isError: Bool,
        maximumCapturedBytes: Int,
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) {
        self.handle = handle
        self.isError = isError
        self.buffer = OutputBuffer(maximumBytes: maximumCapturedBytes)
        self.onOutput = onOutput
        finishGroup.enter()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.finishLock.lock()
            guard !self.didFinish else {
                self.finishLock.unlock()
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                self.didFinish = true
                handle.readabilityHandler = nil
                self.finishLock.unlock()
                self.complete()
                return
            }
            self.buffer.append(data)
            let text = self.decoder.decode(data)
            self.finishLock.unlock()
            if !text.isEmpty {
                self.onOutput?(text, self.isError)
            }
        }
    }

    func forceFinish() {
        finishLock.lock()
        guard !didFinish else {
            finishLock.unlock()
            return
        }
        didFinish = true
        handle.readabilityHandler = nil
        let reachedEndOfFile = drainAvailableBytesWithoutBlocking()
        if !reachedEndOfFile {
            forcedBeforeEndOfFile = true
        }
        finishLock.unlock()

        complete(deliverFinalOutput: false)
    }

    private func drainAvailableBytesWithoutBlocking() -> Bool {
        let descriptor = handle.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0,
              fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            return false
        }

        let deadline = DispatchTime.now() + 0.05
        let maximumForcedDrainBytes = 256 * 1_024
        var drainedByteCount = 0
        var storage = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let byteCount = storage.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                let chunk = Data(storage.prefix(Int(byteCount)))
                buffer.append(chunk)
                _ = decoder.decode(chunk)
                drainedByteCount += Int(byteCount)
                guard drainedByteCount < maximumForcedDrainBytes,
                      DispatchTime.now() < deadline else {
                    return false
                }
                continue
            }
            if byteCount == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                switch waitForPipeDrainEvent(descriptor) {
                case .readable:
                    continue
                case .endOfFile:
                    return true
                case .unresolved:
                    return false
                }
            }
            return false
        }
    }

    private enum PipeDrainEvent {
        case readable
        case endOfFile
        case unresolved
    }

    private func waitForPipeDrainEvent(_ descriptor: Int32) -> PipeDrainEvent {
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        var pollResult: Int32
        repeat {
            // A readability handler can be delayed under thread pressure even
            // after the child has closed its pipe. Give the kernel a short,
            // bounded window to publish POLLHUP before declaring truncation.
            pollResult = Darwin.poll(&descriptorState, 1, 50)
        } while pollResult < 0 && errno == EINTR

        guard pollResult > 0 else {
            return .unresolved
        }
        if descriptorState.revents & Int16(POLLIN) != 0 {
            return .readable
        }
        if descriptorState.revents & Int16(POLLHUP) != 0 {
            return .endOfFile
        }
        return .unresolved
    }

    private func complete(deliverFinalOutput: Bool = true) {
        let finalText = decoder.finish()
        try? handle.close()
        finishGroup.leave()
        if deliverFinalOutput, !finalText.isEmpty {
            onOutput?(finalText, isError)
        }
    }

    func waitUntilFinished() {
        finishGroup.wait()
    }

    func waitUntilFinished(until deadline: DispatchTime) -> Bool {
        finishGroup.wait(timeout: deadline) == .success
    }

    var stringValue: String {
        buffer.stringValue
    }

    var wasTruncated: Bool {
        finishLock.withLock { forcedBeforeEndOfFile }
            || buffer.wasTruncated
    }

    var wasForcedBeforeEndOfFile: Bool {
        finishLock.withLock { forcedBeforeEndOfFile }
    }

}

private final class IncrementalUTF8Decoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func decode(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }

        pending.append(data)
        let suffixLength = incompleteSuffixLength(in: pending)
        let completeCount = pending.count - suffixLength
        guard completeCount > 0 else {
            return ""
        }

        let complete = pending.prefix(completeCount)
        pending = Data(pending.suffix(suffixLength))
        return String(decoding: complete, as: UTF8.self)
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        let final = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: false)
        return final
    }

    private func incompleteSuffixLength(in data: Data) -> Int {
        guard let last = data.last, last >= 0x80 else {
            return 0
        }

        let bytes = [UInt8](data)
        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0,
              bytes[index] & 0xc0 == 0x80,
              continuationCount < 3 {
            continuationCount += 1
            if index == 0 {
                break
            }
            index -= 1
        }

        let leadIndex = bytes.count - continuationCount - 1
        guard leadIndex >= 0 else {
            return 0
        }
        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xc2...0xdf: expectedLength = 2
        case 0xe0...0xef: expectedLength = 3
        case 0xf0...0xf4: expectedLength = 4
        default: return 0
        }
        let actualLength = continuationCount + 1
        return actualLength < expectedLength ? actualLength : 0
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tailChunks: [Data] = []
    private var tailByteCount = 0
    private var totalByteCount = 0
    private static let tailChunkSize = 64 * 1_024

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        self.headLimit = maximumBytes / 2
        self.tailLimit = maximumBytes - headLimit
    }

    func append(_ chunk: Data) {
        lock.lock()
        totalByteCount += chunk.count
        var remainder = chunk
        if head.count < headLimit {
            let headByteCount = min(headLimit - head.count, remainder.count)
            head.append(remainder.prefix(headByteCount))
            remainder = Data(remainder.dropFirst(headByteCount))
        }
        if !remainder.isEmpty {
            var offset = 0
            while offset < remainder.count {
                let chunkByteCount = min(Self.tailChunkSize, remainder.count - offset)
                tailChunks.append(
                    remainder.subdata(in: offset..<(offset + chunkByteCount))
                )
                tailByteCount += chunkByteCount
                offset += chunkByteCount
            }
            while tailByteCount > tailLimit, !tailChunks.isEmpty {
                let excess = tailByteCount - tailLimit
                if excess >= tailChunks[0].count {
                    tailByteCount -= tailChunks.removeFirst().count
                } else {
                    tailChunks[0] = Data(tailChunks[0].dropFirst(excess))
                    tailByteCount -= excess
                }
            }
        }
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let headSnapshot = head
        var tailSnapshot = Data(capacity: tailByteCount)
        for chunk in tailChunks {
            tailSnapshot.append(chunk)
        }
        let capturedByteCount = head.count + tailByteCount
        let omittedByteCount = max(totalByteCount - capturedByteCount, 0)
        lock.unlock()

        guard omittedByteCount > 0 else {
            return String(decoding: headSnapshot + tailSnapshot, as: UTF8.self)
        }
        return String(decoding: headSnapshot, as: UTF8.self)
            + "\n… 已省略 \(omittedByteCount) 字节命令输出 …\n"
            + String(decoding: tailSnapshot, as: UTF8.self)
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalByteCount > head.count + tailByteCount
    }
}
