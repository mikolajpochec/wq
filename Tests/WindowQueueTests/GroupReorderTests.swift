import XCTest
@testable import WindowQueue

final class GroupReorderTests: XCTestCase {
    private func makeModel(_ ids: [CGWindowID]) -> WindowQueueModel {
        let model = WindowQueueModel()
        model.autoSortByWorkspace = false
        model.spaceOrder = [10]
        model.currentSpaceID = 10
        model.reconcile(with: ids.map {
            ManagedWindow(id: $0, element: nil, pid: 1, appName: "App", bundleID: nil,
                          title: "w\($0)", isMinimized: false, spaceID: 10)
        })
        return model
    }

    private func ids(_ model: WindowQueueModel) -> [CGWindowID] { model.windows.map(\.id) }

    func testDraggingInAGroupTradesOnlyTheGroupsPlaces() {
        let model = makeModel([1, 2, 3, 4, 5])
        model.makeGroup([2, 4, 5])
        let before = ids(model)
        let members = before.filter { [2, 4, 5].contains($0) }
        let others = before.filter { ![2, 4, 5].contains($0) }

        // The last member to the front of the group.
        model.move(members[2], toPlaceInGroup: 0)

        let after = ids(model)
        XCTAssertEqual(after.filter { [2, 4, 5].contains($0) }, [members[2], members[0], members[1]])
        XCTAssertEqual(after.filter { ![2, 4, 5].contains($0) }, others, "windows outside the group stay put")
        // The group holds the same places in the queue as before.
        XCTAssertEqual(after.indices.filter { [2, 4, 5].contains(after[$0]) },
                       before.indices.filter { [2, 4, 5].contains(before[$0]) })
    }

    func testDraggingToItsOwnPlaceOrOutsideAGroupDoesNothing() {
        let model = makeModel([1, 2, 3])
        model.makeGroup([1, 2])
        XCTAssertNil(model.queueAfterMoving(3, toPlaceInGroup: 0))
        let first = model.members(of: model.groups[0]).first!.id
        XCTAssertNil(model.queueAfterMoving(first, toPlaceInGroup: 0))
        XCTAssertNotNil(model.queueAfterMoving(first, toPlaceInGroup: 9), "past the end lands last")
    }

    func testReorderingATiledGroupChangesItsLayoutOrder() {
        let model = makeModel([1, 2, 3])
        model.makeGroup([1, 2, 3])
        let group = model.setTiled([1, 2, 3], layout: "Main and stack")!
        let first = model.tiledWindowsInQueueOrder(group).first!.id
        model.move(first, toPlaceInGroup: 2)
        XCTAssertEqual(model.tiledWindowsInQueueOrder(group).last?.id, first)
    }
}
