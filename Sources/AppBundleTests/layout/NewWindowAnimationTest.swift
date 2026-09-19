@testable import AppBundle
import Common
import XCTest

final class NewWindowAnimationTest: XCTestCase {
    private let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)

    func testClosestSideEdgeIsPreferredOverBottomEdge() {
        let target = Rect(topLeftX: 1000, topLeftY: 500, width: 1000, height: 500)
        let start = getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: [])
        assertEquals(start, CGPoint(x: 1999, y: 500))
    }

    func testFullHeightColumnsSlideFromSideEdges() {
        let left = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 1000)
        assertEquals(getNewWindowAnimationStart(target: left, monitor: monitor, otherMonitors: []), CGPoint(x: -799, y: 0))
        let right = Rect(topLeftX: 1200, topLeftY: 0, width: 800, height: 1000)
        assertEquals(getNewWindowAnimationStart(target: right, monitor: monitor, otherMonitors: []), CGPoint(x: 1999, y: 0))
    }

    func testEdgesOccupiedByOtherMonitorsAreSkipped() {
        let target = Rect(topLeftX: 1000, topLeftY: 500, width: 1000, height: 500)
        let right = Rect(topLeftX: 2000, topLeftY: 0, width: 2000, height: 1000)
        assertEquals(
            getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: [right]),
            CGPoint(x: -999, y: 500),
        )
        let leftMonitor = Rect(topLeftX: -2000, topLeftY: 0, width: 2000, height: 1000)
        assertEquals(
            getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: [right, leftMonitor]),
            CGPoint(x: 1000, y: 999), // The bottom edge is the last resort
        )
        let below = Rect(topLeftX: 0, topLeftY: 1000, width: 2000, height: 1000)
        assertEquals(getNewWindowAnimationStart(target: target, monitor: monitor, otherMonitors: [below, right, leftMonitor]), nil)
    }
}
