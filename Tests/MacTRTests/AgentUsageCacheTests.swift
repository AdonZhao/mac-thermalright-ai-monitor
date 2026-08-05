// AgentUsageCacheTests.swift — the collector re-read and re-parsed the same
// unchanged transcript tail every 2s tick; parse results are now cached by
// (path, size, mtime) and recomputed only when the file actually changed.

import Foundation
import Testing

@testable import MacTR

private func makeFakeHome() throws -> (home: String, transcript: String) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("mactr-agent-cache-\(UUID().uuidString)").path
    let projDir = home + "/.claude/projects/test-proj"
    try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
    let transcript = projDir + "/session.jsonl"
    let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}"#
    try (line + "\n").write(toFile: transcript, atomically: false, encoding: .utf8)
    return (home, transcript)
}

@Test("an unchanged transcript is parsed once; growth invalidates the cache")
func transcriptParseIsCached() throws {
    let (home, transcript) = try makeFakeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    let collector = AgentUsageCollector(home: home)
    _ = collector.collect()
    _ = collector.collect()
    _ = collector.collect()
    #expect(collector.activityParses == 1)

    let fh = try #require(FileHandle(forWritingAtPath: transcript))
    fh.seekToEndOfFile()
    fh.write(Data(#"{"type":"user","message":"more"}"#.utf8) + Data("\n".utf8))
    try fh.close()

    _ = collector.collect()
    #expect(collector.activityParses == 2)
}

@Test("cached and fresh parses produce the same usage")
func cachedParseMatchesFresh() throws {
    let (home, _) = try makeFakeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    let collector = AgentUsageCollector(home: home)
    let first = collector.collect()
    let second = collector.collect()

    #expect(first.claude.project == second.claude.project)
    #expect(first.claude.activity == second.claude.activity)
    #expect(first.claude.model == second.claude.model)
}
