import AppKit
import XCTest
@testable import Ablage

final class MenuPanelTests: XCTestCase {
    func testContentChangesOnlyMoveTheBottomEdge() {
        let screen = NSRect(x: 0, y: 30, width: 1440, height: 840)
        let anchor = NSRect(x: 1000, y: 870, width: 24, height: 30)
        let short = MenuPanel.frame(contentSize: NSSize(width: 380, height: 220), anchor: anchor, visibleFrame: screen)
        let tall = MenuPanel.frame(contentSize: NSSize(width: 380, height: 580), anchor: anchor, visibleFrame: screen)
        XCTAssertEqual(short.maxY, anchor.minY)
        XCTAssertEqual(tall.maxY, short.maxY)
        XCTAssertEqual(tall.minX, short.minX)
        XCTAssertLessThan(tall.minY, short.minY)
    }

    func testPanelStaysOnTheAnchorsDisplayIncludingNegativeCoordinates() {
        let screen = NSRect(x: -1920, y: 24, width: 1920, height: 1032)
        for x in [-1915.0, -26.0] {
            let anchor = NSRect(x: x, y: 1056, width: 24, height: 24)
            let panel = MenuPanel.frame(contentSize: NSSize(width: 440, height: 600), anchor: anchor, visibleFrame: screen)
            XCTAssertGreaterThanOrEqual(panel.minX, screen.minX + 8)
            XCTAssertLessThanOrEqual(panel.maxX, screen.maxX - 8)
            XCTAssertEqual(panel.maxY, 1056)
        }
    }

    func testShortDisplayKeepsPanelAboveTheDock() {
        let screen = NSRect(x: 0, y: 70, width: 1024, height: 600)
        let panel = MenuPanel.frame(contentSize: NSSize(width: 440, height: 900), anchor: NSRect(x: 900, y: 670, width: 24, height: 28), visibleFrame: screen)
        XCTAssertEqual(panel.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(panel.minY, screen.minY + 8)
    }
}
