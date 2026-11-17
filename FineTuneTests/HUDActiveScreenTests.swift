// FineTuneTests/HUDActiveScreenTests.swift
import AppKit
import Testing
@testable import FineTune

@Suite("HUD active screen")
@MainActor
struct HUDActiveScreenTests {
    // Primary 1440×900 at origin; external 1920×1080 to its right, bottom-aligned.
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let external = NSRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test("picks the screen under the pointer")
    func picksPointerScreen() {
        #expect(HUDWindowController.screenIndex(containing: NSPoint(x: 100, y: 100), in: [primary, external]) == 0)
        #expect(HUDWindowController.screenIndex(containing: NSPoint(x: 2000, y: 500), in: [primary, external]) == 1)
    }

    @Test("pointer resting on the top edge still counts")
    func topEdge() {
        #expect(HUDWindowController.screenIndex(containing: NSPoint(x: 2000, y: 1080), in: [primary, external]) == 1)
    }

    @Test("pointer outside every screen returns nil")
    func outside() {
        #expect(HUDWindowController.screenIndex(containing: NSPoint(x: 100, y: 1000), in: [primary, external]) == nil)
    }

    @Test("converts AppKit frames to CGWindow coordinates")
    func cgConversion() {
        // External is 180pt taller than primary, so its top sits 180pt above the CG origin.
        let cg = HUDWindowController.cgFrame(fromAppKit: external, primaryScreenFrame: primary)
        #expect(cg == CGRect(x: 1440, y: -180, width: 1920, height: 1080))
    }

    @Test("fullscreen window only counts on its own screen")
    func fullscreenPerScreen() {
        let externalCG = HUDWindowController.cgFrame(fromAppKit: external, primaryScreenFrame: primary)
        let primaryCG = HUDWindowController.cgFrame(fromAppKit: primary, primaryScreenFrame: primary)
        let fullscreenOnExternal = externalCG

        #expect(HUDWindowController.windowCoversScreen(windowBounds: fullscreenOnExternal, screenCGFrame: externalCG))
        #expect(!HUDWindowController.windowCoversScreen(windowBounds: fullscreenOnExternal, screenCGFrame: primaryCG))
        #expect(!HUDWindowController.windowCoversScreen(
            windowBounds: CGRect(x: 1500, y: 0, width: 800, height: 600),
            screenCGFrame: externalCG
        ))
    }
}
