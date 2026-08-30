import XCTest
import integration_test

// Bridges the Dart integration_test suite into the RunnerTests XCUITest target
// so it runs on a physical device over CoreDevice (`xcodebuild test`) — the
// path that works when the iPhone is tethered WIRELESSLY (plain
// `flutter test integration_test` cannot launch on a wireless iOS device).
class RunnerTests: XCTestCase {
  func testIntegrationTest() {
    var testResult: NSString?
    let ok = IntegrationTestIosTest().testIntegrationTest(&testResult)
    XCTAssertTrue(ok, (testResult as String?) ?? "integration test failed")
  }
}
