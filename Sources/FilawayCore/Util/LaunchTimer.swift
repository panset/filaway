import Darwin
import Foundation

/// Launch-time probe for the "<2 s to editable" budget (NFR-1, plan §4).
///
/// XCTest's `XCTApplicationLaunchMetric` needs Xcode, which this machine does
/// not have (plan §8), so the shell marks the three moments that matter and
/// this prints them when `FILAWAY_TIMING=1`:
///
/// ```
/// [timing] windowVisible  +412 ms
/// [timing] editorReady    +684 ms
/// ```
///
/// `processStart` defaults to the kernel's record of when the process was
/// exec'd, so the number includes dyld and framework load — the part a
/// stopwatch inside `main()` would miss. Marking it explicitly overrides that.
public enum LaunchTimer {
    public enum Milestone: String, Sendable, CaseIterable {
        case processStart
        case windowVisible
        case editorReady
    }

    /// Records a milestone, printing it when `FILAWAY_TIMING=1`.
    public static func mark(_ milestone: Milestone, at date: Date = Date()) {
        let elapsed = state.record(milestone, at: date)
        guard isEnabled else { return }
        let name = milestone.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        print("[timing] \(name) +\(Int((elapsed * 1000).rounded())) ms")
    }

    /// Seconds from `processStart` to a milestone, or `nil` if unmarked.
    public static func elapsed(to milestone: Milestone) -> TimeInterval? {
        state.elapsed(to: milestone)
    }

    /// Every marked milestone, in order, as `"name +N ms"` lines.
    public static func report() -> String {
        Milestone.allCases.compactMap { milestone in
            guard let elapsed = state.elapsed(to: milestone) else { return nil }
            return "\(milestone.rawValue) +\(Int((elapsed * 1000).rounded())) ms"
        }.joined(separator: ", ")
    }

    /// Forgets every mark. Tests only.
    public static func reset() { state.reset() }

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FILAWAY_TIMING"] == "1"
    }

    // MARK: - Storage

    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [Milestone: Date] = [:]
        private var start: Date?

        func record(_ milestone: Milestone, at date: Date) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            if milestone == .processStart || start == nil {
                start = milestone == .processStart ? date : (LaunchTimer.processStartDate ?? date)
            }
            marks[milestone] = date
            return date.timeIntervalSince(start ?? date)
        }

        func elapsed(to milestone: Milestone) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard let mark = marks[milestone], let start else { return nil }
            return mark.timeIntervalSince(start)
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            marks = [:]
            start = nil
        }
    }

    /// When the kernel exec'd this process, from `kinfo_proc`.
    static var processStartDate: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        let result = name.withUnsafeMutableBufferPointer { pointer -> Int32 in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
