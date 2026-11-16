import XCTest

extension XCUIApplication {
    /// Clip List's tile for clip `number`, counted from 1.
    func clipTile(_ number: Int) -> XCUIElement {
        descendants(matching: .any).matching(identifier: "clip-tile-\(number)").firstMatch
    }

    /// Opens Name Clips the way the app does, from a harness that lands on Clip List: taps clip
    /// `number`'s tile and waits for Name Clips' counter, "`number` of `count`". Returns whether
    /// it got there.
    func openNameClips(atClip number: Int, of count: Int) -> Bool {
        guard navigationBars["Clips"].waitForExistence(timeout: 15) else { return false }
        let tile = clipTile(number)
        guard tile.waitForExistence(timeout: 15) else { return false }
        tile.tap()
        return navigationBars["\(number) of \(count)"].waitForExistence(timeout: 15)
    }
}
