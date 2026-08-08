import XCTest

@testable import SplitSound

/// Covers the path rule that attributes a nested helper executable to the app
/// it lives inside.
///
/// Pure path arithmetic, so these do not depend on which apps are installed —
/// the Electron case in particular would otherwise only be testable on a
/// machine that happens to have such an app.
final class AppIdentityTests: XCTestCase {
    func testElectronHelperResolvesToOuterApp() {
        // The layout Discord, Slack, VS Code and friends all share.
        let path = "/Applications/Discord.app/Contents/Frameworks/"
            + "Discord Helper.app/Contents/MacOS/Discord Helper"
        XCTAssertEqual(
            AppIdentity.outermostAppBundle(forExecutableAt: path)?.path,
            "/Applications/Discord.app"
        )
    }

    func testOutermostBundleWinsOverNestedOne() {
        // Three levels of nesting: the outermost must still be the answer,
        // otherwise the row would be labelled with the helper's own name.
        let path = "/Applications/Outer.app/Contents/Frameworks/"
            + "Middle.app/Contents/Frameworks/Inner.app/Contents/MacOS/Inner"
        XCTAssertEqual(
            AppIdentity.outermostAppBundle(forExecutableAt: path)?.path,
            "/Applications/Outer.app"
        )
    }

    func testPlainAppResolvesToItself() {
        let path = "/Applications/Safari.app/Contents/MacOS/Safari"
        XCTAssertEqual(
            AppIdentity.outermostAppBundle(forExecutableAt: path)?.path,
            "/Applications/Safari.app"
        )
    }

    func testCommandLineToolHasNoBundle() {
        XCTAssertNil(AppIdentity.outermostAppBundle(forExecutableAt: "/usr/sbin/systemsoundserverd"))
        XCTAssertNil(AppIdentity.outermostAppBundle(forExecutableAt: "/usr/bin/afplay"))
    }

    func testXPCServiceInFrameworkIsNotAttributedToAnApp() {
        // WebKit's audio service lives in a framework, not inside Safari.app.
        // The path rule must not invent a host here — that case is handled by
        // the separate name heuristic.
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/"
            + "XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertNil(AppIdentity.outermostAppBundle(forExecutableAt: path))
    }

    func testAppBundleInsideAnXPCServiceIsStillFound() {
        // Guards the loop against stopping at the first match from the bottom.
        let path = "/Applications/Host.app/Contents/XPCServices/"
            + "Service.xpc/Contents/MacOS/Service"
        XCTAssertEqual(
            AppIdentity.outermostAppBundle(forExecutableAt: path)?.path,
            "/Applications/Host.app"
        )
    }
}
