// LYProtocolChunkTests.swift — frame chunking must not emit an empty chunk
// when the JPEG size is an exact multiple of the chunk payload size.

import Foundation
import Testing

@testable import MacTR

@Test("exact multiple of 496 fills the last chunk instead of adding an empty one")
func exactMultipleHasNoEmptyChunk() {
    let layout = LYProtocol.chunkLayout(totalSize: 496 * 3)
    #expect(layout.count == 3)
    #expect(layout.lastDataLen == 496)
}

@Test("one byte over rolls into a new final chunk")
func remainderRollsIntoFinalChunk() {
    let layout = LYProtocol.chunkLayout(totalSize: 496 * 3 + 1)
    #expect(layout.count == 4)
    #expect(layout.lastDataLen == 1)
}

@Test("tiny frame fits one chunk")
func tinyFrameFitsOneChunk() {
    let layout = LYProtocol.chunkLayout(totalSize: 1)
    #expect(layout.count == 1)
    #expect(layout.lastDataLen == 1)
}

@Test("empty frame keeps the historical single empty chunk")
func emptyFrameKeepsSingleEmptyChunk() {
    let layout = LYProtocol.chunkLayout(totalSize: 0)
    #expect(layout.count == 1)
    #expect(layout.lastDataLen == 0)
}
