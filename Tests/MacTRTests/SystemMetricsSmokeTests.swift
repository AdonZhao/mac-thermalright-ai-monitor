// SystemMetricsSmokeTests.swift — the fixed hardware facts must be sane and
// stable across collections (they are read once at init and cached).

import Foundation
import Testing

@testable import MacTR

@Test("hardware constants are sane and identical across collections")
func hardwareConstantsAreStable() {
    let collector = SystemMetricsCollector()

    let cpu1 = collector.collectCPU()
    let mem1 = collector.collectMemory()
    let cpu2 = collector.collectCPU()
    let mem2 = collector.collectMemory()

    #expect(cpu1.pCoreCount > 0)
    #expect(cpu1.pCoreCount == cpu2.pCoreCount)
    #expect(mem1.total > 1 << 30)
    #expect(mem1.total == mem2.total)
}
