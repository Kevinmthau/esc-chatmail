import Foundation
import ObjectiveC

/// Records the query plans SQLite reports for the SQL Core Data runs.
///
/// A fetch request's plan cannot be had by writing the SQL out by hand: the
/// SQL is Core Data's, and it changes with the predicate's form (an object
/// against a joined `conversation.id`, `ANY` against `SUBQUERY`). So this
/// turns on Core Data's own SQL debugging for the length of a closure. At
/// level 4 the SQLite store asks SQLite for the plan of each statement on the
/// connection that then runs it, and writes the SQL and the plan's rows to
/// standard error, which is read back here.
///
/// Two things about it are not public API, and both were measured on the
/// iOS 27.0 simulator (2026-11-16):
/// - `+[NSSQLCore setDebugDefault:]` and `+debugDefault`, the switch behind
///   the `-com.apple.CoreData.SQLDebug` launch argument. The argument itself
///   is read once, before any test runs, and at level 4 it would log every
///   statement of a store being seeded.
/// - The plan's rows go to standard error only. The unified log gets the SQL
///   and the bindings but not the rows, so `OSLogStore` cannot stand in.
///
/// If either changes, `record` throws or returns no plans, and
/// `SQLiteQueryPlanRecorderTests` (default test plan) fails. A test must never
/// read "no plans" as "no scans": assert that the plan it wants was recorded
/// before asserting anything about it.
///
/// The switch and the redirect are process-wide. Tests in one process run one
/// at a time, so a recording sees its own statements plus whatever other
/// contexts in the process run meanwhile; pick plans out by their SQL.
enum SQLiteQueryPlanRecorder {
    /// One statement and the rows of its plan, in SQLite's order.
    struct Plan: Equatable, CustomStringConvertible {
        let sql: String
        /// The `detail` column of each `EXPLAIN QUERY PLAN` row, such as
        /// `SEARCH t0 USING INDEX Z_Message_byConversationAndDateIndex (ZCONVERSATION=?)`.
        let steps: [String]

        var description: String {
            ([sql] + steps.map { "    " + $0 }).joined(separator: "\n")
        }

        /// Whether the statement reads `table` (`ZMESSAGE`) at all.
        func reads(_ table: String) -> Bool {
            !aliases(of: table).isEmpty
        }

        /// The aliases Core Data gave `table` in this statement (`t0`).
        func aliases(of table: String) -> [String] {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: table)) (t[0-9]+)\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(sql.startIndex..., in: sql)
            return expression.matches(in: sql, range: range).compactMap { match in
                Range(match.range(at: 1), in: sql).map { String(sql[$0]) }
            }
        }

        /// The plan's rows that walk `table` from one end, with or without an
        /// index: `SCAN t0` and `SCAN t0 USING INDEX …`. A `SEARCH` row is a
        /// lookup and is not one of them.
        func scans(of table: String) -> [String] {
            let tableAliases = aliases(of: table)
            return steps.filter { step in
                tableAliases.contains { alias in
                    step == "SCAN \(alias)" || step.hasPrefix("SCAN \(alias) ")
                }
            }
        }

        /// The names of the indexes the plan uses on `table`.
        func indexes(on table: String) -> [String] {
            let tableAliases = aliases(of: table)
            return steps.compactMap { step in
                guard tableAliases.contains(where: { step.contains(" \($0) ") }),
                      let range = step.range(of: "INDEX ") else {
                    return nil
                }
                return step[range.upperBound...].split(separator: " ").first.map(String.init)
            }
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case debugSwitchUnavailable
        case redirectFailed(String)

        var description: String {
            switch self {
            case .debugSwitchUnavailable:
                return "Core Data's SQL debug switch (+[NSSQLCore setDebugDefault:]) was not found"
            case .redirectFailed(let step):
                return "Standard error could not be redirected (\(step))"
            }
        }
    }

    /// The plans of every statement Core Data's SQLite stores ran during `body`.
    static func record(_ body: () throws -> Void) throws -> [Plan] {
        let session = try Session()
        do {
            try body()
        } catch {
            _ = session.end()
            throw error
        }
        return parse(session.end())
    }

    /// The plans of every statement Core Data's SQLite stores ran during `body`.
    static func record(_ body: () async throws -> Void) async throws -> [Plan] {
        let session = try Session()
        do {
            try await body()
        } catch {
            _ = session.end()
            throw error
        }
        return parse(session.end())
    }

    /// Core Data's SQL debug level: 0 unless a recording is running or the
    /// process was launched with `-com.apple.CoreData.SQLDebug`.
    static func currentDebugLevel() throws -> Int32 {
        try DebugSwitch.level()
    }

    /// Reads plans out of what Core Data wrote. A plan starts at a
    /// `CoreData: details: SQLite: <sql>` line and is the numbered rows right
    /// after it; a statement with no rows after it is not a plan.
    static func parse(_ log: String) -> [Plan] {
        let statementPrefix = "CoreData: details: SQLite: "
        var plans: [Plan] = []
        var sql: String?
        var steps: [String] = []

        func finish() {
            if let sql, !steps.isEmpty {
                plans.append(Plan(sql: sql, steps: steps))
            }
            sql = nil
            steps = []
        }

        for line in log.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(statementPrefix) {
                finish()
                sql = String(line.dropFirst(statementPrefix.count))
            } else if sql != nil, let step = planStep(in: line) {
                steps.append(step)
            } else {
                finish()
            }
        }
        finish()
        return plans
    }

    /// The detail of a plan row (`     6 0 212 SCAN t0`: id, parent, an unused
    /// column, detail), or nil for any other line.
    private static func planStep(in line: Substring) -> String? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count == 4, fields.prefix(3).allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return String(fields[3])
    }

    /// Core Data's SQL debug level, read and set through `NSSQLCore`.
    private enum DebugSwitch {
        private typealias Setter = @convention(c) (AnyClass, Selector, Int32) -> Void
        private typealias Getter = @convention(c) (AnyClass, Selector) -> Int32

        static func level() throws -> Int32 {
            let selector = NSSelectorFromString("debugDefault")
            guard let storeClass = NSClassFromString("NSSQLCore"),
                  let method = class_getClassMethod(storeClass, selector) else {
                throw RecorderError.debugSwitchUnavailable
            }
            let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            return getter(storeClass, selector)
        }

        static func setLevel(_ level: Int32) throws {
            let selector = NSSelectorFromString("setDebugDefault:")
            guard let storeClass = NSClassFromString("NSSQLCore"),
                  let method = class_getClassMethod(storeClass, selector) else {
                throw RecorderError.debugSwitchUnavailable
            }
            let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            setter(storeClass, selector, level)
        }
    }

    /// One recording: standard error goes to a file and the debug level to 4
    /// until `end()`. A file and not a pipe, because a pipe's buffer is 64 KB
    /// and a writer blocks once it is full.
    private final class Session {
        private let logURL: URL
        private let logDescriptor: Int32
        private let savedStandardError: Int32
        private let savedLevel: Int32

        init() throws {
            savedLevel = try DebugSwitch.level()
            logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SQLiteQueryPlanRecorder-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                throw RecorderError.redirectFailed("create the log file")
            }
            logDescriptor = open(logURL.path, O_WRONLY | O_APPEND)
            guard logDescriptor >= 0 else {
                try? FileManager.default.removeItem(at: logURL)
                throw RecorderError.redirectFailed("open the log file")
            }
            fflush(stderr)
            savedStandardError = dup(STDERR_FILENO)
            guard savedStandardError >= 0, dup2(logDescriptor, STDERR_FILENO) >= 0 else {
                close(logDescriptor)
                try? FileManager.default.removeItem(at: logURL)
                throw RecorderError.redirectFailed("duplicate the descriptor")
            }
            do {
                try DebugSwitch.setLevel(4)
            } catch {
                restoreStandardError()
                throw error
            }
        }

        private func restoreStandardError() {
            fflush(stderr)
            dup2(savedStandardError, STDERR_FILENO)
            close(savedStandardError)
            close(logDescriptor)
        }

        func end() -> String {
            try? DebugSwitch.setLevel(savedLevel)
            restoreStandardError()
            defer { try? FileManager.default.removeItem(at: logURL) }
            guard let data = try? Data(contentsOf: logURL) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
