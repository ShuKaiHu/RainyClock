// Compiles only for a render run (see the class comment); an empty file otherwise.
#if WIDGET_RENDER
import SwiftUI
import WidgetKit
import XCTest
@testable import RainyClock

/// Renders the three Lock Screen faces of the "Next Alarm" widget for every sample scenario
/// into PNG files, for a visual review. No simulator can place a Lock Screen widget from the
/// command line (the editor only accepts a real long press, and Xcode 27's simulators refuse
/// the accessory families in the picker), so the faces are drawn here with `ImageRenderer`
/// at the sizes WidgetKit uses on an iPhone 17 Pro. The ink is the system's hierarchical
/// styles over a dark backdrop, not WidgetKit's vibrant material; layout, wrapping and
/// truncation are what this is for.
///
/// Skipped unless `WIDGET_RENDER_DIR` is set (`TEST_RUNNER_WIDGET_RENDER_DIR` on the
/// xcodebuild command line). The language follows the simulator's system language, as the
/// widget's does.
@MainActor
final class LockScreenWidgetRenderTests: XCTestCase {
    private static let faces: [(family: WidgetFamily, name: String, size: CGSize)] = [
        (.accessoryRectangular, "rectangular", CGSize(width: 162, height: 72)),
        (.accessoryCircular, "circular", CGSize(width: 72, height: 72)),
        (.accessoryInline, "inline", CGSize(width: 300, height: 24)),
    ]

    func testRenderEveryScenarioForReview() throws {
        guard let directory = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WIDGET_RENDER_DIR to render the Lock Screen faces.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // The widget's strings live in the extension, embedded in the test host under PlugIns.
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("PlugIns/RainyClockAlarmWidget.appex")
        let widgetBundle = try XCTUnwrap(Bundle(url: extensionURL), "widget extension bundle")
        XCTAssertNotEqual(widgetBundle.localizedString(forKey: "widget_display_name", value: nil, table: nil),
                          "widget_display_name", "widget strings resolve from the extension bundle")
        let now = Date()
        var written = 0
        // The default text size, and the largest non-accessibility one: the Lock Screen
        // follows the phone's Dynamic Type, which is where "Tomorrow · Sat" ran out of room.
        let typeSizes: [(DynamicTypeSize, String)] = [(.large, ""), (.xxxLarge, "-xxxl")]
        for (index, scenario) in TomorrowWidgetSamples.Scenario.allCases.enumerated() {
            let entry = TomorrowWidgetEntry.sample(scenario, now: now)
            for face in Self.faces {
                for (typeSize, suffix) in typeSizes {
                    let content = TomorrowWidgetReviewFace(entry: entry, family: face.family, bundle: widgetBundle)
                        .frame(width: face.size.width, height: face.size.height)
                        .environment(\.widgetRenderingMode, .vibrant)
                        .environment(\.colorScheme, .dark)
                        .environment(\.dynamicTypeSize, typeSize)
                        .padding(6)
                        .background(Color(white: 0.16))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 3
                    renderer.isOpaque = true
                    let image = try XCTUnwrap(renderer.uiImage, "\(scenario) \(face.name)")
                    let data = try XCTUnwrap(image.pngData())
                    let name = String(format: "%02d-%@-%@%@.png", index + 1, scenario.rawValue, face.name, suffix)
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    written += 1
                }
            }
        }
        XCTAssertEqual(written, TomorrowWidgetSamples.Scenario.allCases.count * Self.faces.count * typeSizes.count)
    }
}
#endif
