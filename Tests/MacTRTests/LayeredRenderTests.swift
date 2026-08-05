// LayeredRenderTests.swift — the layered (cached) frame composition must look
// exactly like drawing the whole scene directly, and must stop redrawing the
// static content when the data hasn't changed.

import CoreGraphics
import Foundation
import Testing

@testable import MacTR

// MARK: - Fixtures

private let t0 = 1_700_000_000.0

private func makeContext() -> CGContext? {
    let w = Layout.width, h = Layout.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

private func pixels(_ ctx: CGContext) -> [UInt8] {
    guard let data = ctx.data else { return [] }
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                     count: ctx.bytesPerRow * ctx.height))
}

/// Difference summary between two renderings: the worst per-channel delta, and
/// how many channel values differ by more than the compositing-rounding floor.
/// Compositing text through a transparent intermediate layer legitimately adds
/// small deltas on anti-aliased glyph edges (sparse, low single digits — larger
/// where the backdrop is a strong tint). Anything structural — an element drawn
/// shifted, missing, or in the wrong order — produces large deltas across many
/// pixels and fails both bounds.
private struct DiffStats: Equatable, CustomStringConvertible {
    var worst = 0
    var loose = 0   // channels differing by > 3
    var total = 0
    var bbox: (minX: Int, minY: Int, maxX: Int, maxY: Int)?

    static func == (a: DiffStats, b: DiffStats) -> Bool {
        a.worst == b.worst && a.loose == b.loose && a.total == b.total
    }

    var description: String {
        let box = bbox.map { "x\($0.minX)-\($0.maxX) y\($0.minY)-\($0.maxY)" } ?? "none"
        return "worst=\(worst) loose=\(loose)/\(total) box=\(box)"
    }
    var acceptable: Bool {
        total > 0 && worst <= 24 && Double(loose) / Double(total) <= 0.005
    }
}

private func diffStats(_ a: [UInt8], _ b: [UInt8]) -> DiffStats {
    var s = DiffStats()
    guard a.count == b.count, !a.isEmpty else { return s }
    s.total = a.count
    for i in 0..<a.count {
        let d = abs(Int(a[i]) - Int(b[i]))
        s.worst = max(s.worst, d)
        if d > 3 {
            s.loose += 1
            let px = i / 4
            let x = px % Layout.width, y = px / Layout.width
            if let box = s.bbox {
                s.bbox = (min(box.minX, x), min(box.minY, y),
                          max(box.maxX, x), max(box.maxY, y))
            } else {
                s.bbox = (x, y, x, y)
            }
        }
    }
    return s
}

private let cpuA = CPUSnapshot(perCore: [12, 34, 56, 78], total: 45,
                               loadAvg: (1.0, 1.2, 1.4), pCoreCount: 2)
private let cpuB = CPUSnapshot(perCore: [90, 80, 70, 60], total: 75,
                               loadAvg: (4.0, 3.0, 2.0), pCoreCount: 2)
private let memA = MemorySnapshot(
    total: 32 << 30, active: 8 << 30, wired: 4 << 30, compressed: 2 << 30,
    available: 16 << 30, swapUsed: 0, swapTotal: 0, swapInPerSec: 0,
    swapOutPerSec: 0, swapAvailable: true, pressure: 1)
private let tempA = TemperatureSnapshot(cpuTemp: 55, gpuTemp: 50, thermalState: 0)
private let sysA = SystemSnapshot(uptimeSeconds: 100_000, processCount: 412)

private let idleUsage = AgentUsage(
    available: true, todayInputTokens: 123_456, todayOutputTokens: 7890,
    secondsSinceActive: 600, project: "demo-project", activity: "空闲")
private let workingUsage = AgentUsage(
    available: true, todayInputTokens: 2_345_678, todayOutputTokens: 98_765,
    secondsSinceActive: 5, project: "mac-thermalright-ai-monitor",
    activity: "正在重构渲染层，这是一段足够长的中文活动描述，用来驱动折行和多行布局。",
    isWorking: true, model: "claude-fable-5", stepCurrent: 2, stepTotal: 5)
private let attentionUsage = AgentUsage(
    available: true, todayInputTokens: 555_555, todayOutputTokens: 44_444,
    secondsSinceActive: 30, project: "review-branch", activity: "等待确认 | 权限请求",
    quotaUsedPercent: 40, quotaResetsAt: Date(timeIntervalSince1970: t0 + 7200),
    needsAttention: true, waitingFor: "permission prompt")

private func agentsPair(_ claude: AgentUsage, _ codex: AgentUsage) -> AgentsSnapshot {
    AgentsSnapshot(claude: claude, codex: codex)
}

// MARK: - Tests

/// Serialized: these compare pixel output of two render paths, which requires
/// deterministic glyph rasterization — concurrent CoreText use from parallel
/// tests perturbs anti-aliased edge pixels and flakes the comparison.
@Suite(.serialized) struct LayeredRenderTests {

    @Test("layered composition matches direct rendering, idle / working / attention",
          arguments: [
              (idleUsage, idleUsage),
              (workingUsage, idleUsage),
              (attentionUsage, workingUsage),
          ])
    func layeredMatchesDirect(pair: (AgentUsage, AgentUsage)) throws {
        let renderer = MonitorRenderer()
        let agents = agentsPair(pair.0, pair.1)
        let direct = try #require(makeContext())
        let layered = try #require(makeContext())

        renderer.renderScene(direct, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                             agents: agents, t: t0)
        renderer.composeLayeredFrame(layered, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0)

        let stats = diffStats(pixels(direct), pixels(layered))
        #expect(stats.acceptable, Comment(rawValue: stats.description))
    }

    @Test("layered composition matches direct rendering at a second animation phase")
    func layeredMatchesDirectAtOtherPhase() throws {
        let renderer = MonitorRenderer()
        let agents = agentsPair(workingUsage, attentionUsage)
        let direct = try #require(makeContext())
        let layered = try #require(makeContext())

        // Prime the cache at t0 so the second compose reuses cached layers
        renderer.composeLayeredFrame(layered, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0)

        renderer.renderScene(direct, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                             agents: agents, t: t0 + 1.25)
        renderer.composeLayeredFrame(layered, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 1.25)

        let stats = diffStats(pixels(direct), pixels(layered))
        #expect(stats.acceptable, Comment(rawValue: stats.description))
    }

    @Test("static layers rebuild only when the data changes")
    func staticLayersRebuildOnDataChangeOnly() throws {
        let renderer = MonitorRenderer()
        let agents = agentsPair(workingUsage, idleUsage)
        let ctx = try #require(makeContext())

        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0)
        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 0.066)
        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 0.133)
        #expect(renderer.staticLayerRebuilds == 1)

        renderer.composeLayeredFrame(ctx, cpu: cpuB, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 0.2)
        #expect(renderer.staticLayerRebuilds == 2)
    }

    @Test("a CPU change rebuilds the base but does not re-layout the agent columns")
    func cpuChangeDoesNotRebuildColumns() throws {
        let renderer = MonitorRenderer()
        let agents = agentsPair(workingUsage, idleUsage)
        let ctx = try #require(makeContext())

        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0)
        renderer.composeLayeredFrame(ctx, cpu: cpuB, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 0.5)

        #expect(renderer.staticLayerRebuilds == 2)
        #expect(renderer.columnsRebuilds == 1)
    }

    @Test("an agent activity change rebuilds the columns but not the base")
    func agentChangeDoesNotRebuildBase() throws {
        let renderer = MonitorRenderer()
        let ctx = try #require(makeContext())

        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agentsPair(workingUsage, idleUsage), t: t0)
        var changed = workingUsage
        changed = AgentUsage(
            available: true, todayInputTokens: changed.todayInputTokens,
            todayOutputTokens: changed.todayOutputTokens,
            secondsSinceActive: changed.secondsSinceActive, project: changed.project,
            activity: "换了一条新的活动消息", isWorking: true,
            model: changed.model, stepCurrent: changed.stepCurrent,
            stepTotal: changed.stepTotal)
        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agentsPair(changed, idleUsage), t: t0 + 0.5)

        #expect(renderer.staticLayerRebuilds == 1)
        #expect(renderer.columnsRebuilds == 2)
    }

    @Test("a seconds-since-active tick with the same display text skips the rebuild")
    func displayEquivalentAgentTickSkipsRebuild() throws {
        let renderer = MonitorRenderer()
        let ctx = try #require(makeContext())

        // 5s and 7s both display as "now" (< 90s) — no visible difference
        let atFive = workingUsage
        let atSeven = AgentUsage(
            available: true, todayInputTokens: atFive.todayInputTokens,
            todayOutputTokens: atFive.todayOutputTokens,
            secondsSinceActive: 7, project: atFive.project,
            activity: atFive.activity, isWorking: true,
            model: atFive.model, stepCurrent: atFive.stepCurrent,
            stepTotal: atFive.stepTotal)

        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agentsPair(atFive, idleUsage), t: t0)
        renderer.composeLayeredFrame(ctx, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agentsPair(atSeven, idleUsage), t: t0 + 0.5)
        #expect(renderer.columnsRebuilds == 1)

        // and the cached columns must still match drawing the new data directly
        let direct = try #require(makeContext())
        let layered = try #require(makeContext())
        renderer.renderScene(direct, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                             agents: agentsPair(atSeven, idleUsage), t: t0 + 0.5)
        renderer.composeLayeredFrame(layered, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agentsPair(atSeven, idleUsage), t: t0 + 0.5)
        let stats = diffStats(pixels(direct), pixels(layered))
        #expect(stats.acceptable, Comment(rawValue: stats.description))
    }

    @Test("animation keeps moving between frames with identical data")
    func animationMovesWithoutDataChange() throws {
        let renderer = MonitorRenderer()
        let agents = agentsPair(workingUsage, idleUsage)
        let frame1 = try #require(makeContext())
        let frame2 = try #require(makeContext())

        // 1.25s apart lands the working column's breathing at a different alpha
        renderer.composeLayeredFrame(frame1, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0)
        renderer.composeLayeredFrame(frame2, cpu: cpuA, mem: memA, temp: tempA, sys: sysA,
                                     agents: agents, t: t0 + 1.25)

        #expect(pixels(frame1) != pixels(frame2))
    }

}
