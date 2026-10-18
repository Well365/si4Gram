import XCTest
@testable import SecutgCore

/// Mirrors `src/secutg/ui/phone/layout.test.ts` in the Web client: the same arithmetic has to produce the same
/// picture on every client, so the same properties are asserted here (PLAN.md 3.15).
/// The guide content itself is the generated `SecutgGuideData` source shared with TelegramCore.
final class SecutgPhoneLayoutTests: XCTestCase {
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    private static let guide: SecutgGuide = {
        do {
            return try SecutgGuide.parse(json: SecutgGuideData.json)
        } catch {
            fatalError("SecutgGuideData.json does not parse: \(error)")
        }
    }()

    // MARK: text measuring

    func testWrapsLatinAtSpacesAndCJKAnywhere() {
        let latin = SecutgPhoneLayout.wrapText("the quick brown fox jumps over the lazy dog", 60, 8)
        XCTAssertGreaterThan(latin.count, 1)
        XCTAssertEqual(latin.joined(separator: " "), "the quick brown fox jumps over the lazy dog")
        for line in latin { XCTAssertFalse(line.hasPrefix(" ")) }

        let cjk = SecutgPhoneLayout.wrapText("为了防止中间渠道替换密钥请核对安全码", 60, 8)
        XCTAssertGreaterThan(cjk.count, 1)
        XCTAssertEqual(cjk.joined(), "为了防止中间渠道替换密钥请核对安全码")
    }

    func testEveryWrappedLineFitsTheWidthItWasGiven() {
        let text = "接受后，双方消息将在设备上加密，Telegram server only sees ciphertext"
        for line in SecutgPhoneLayout.wrapText(text, 90, 7.5) {
            XCTAssertLessThanOrEqual(SecutgPhoneLayout.textWidth(line, 7.5), 90 + 8)
        }
    }

    func testAMissingLanguageFallsBackToEnglishNeverToAnEmptyString() {
        XCTAssertEqual(SecutgPhoneLayout.pick(["en": "Next", "zh-Hans": "下一步"], "zh-Hant"), "Next")
        XCTAssertEqual(SecutgPhoneLayout.pick(["en": "Next"], "en"), "Next")
        XCTAssertEqual(SecutgPhoneLayout.pick(nil, "en"), "")
    }

    // MARK: guide scenes (PLAN.md 3.15)

    func testTheChaptersAreTheFourTheGuidePromisesWithNoEmptyStep() {
        let guide = Self.guide
        XCTAssertEqual(guide.chapters.map({ $0.id }), SecutgGuide.chapterOrder)
        for chapter in guide.chapters {
            XCTAssertGreaterThan(chapter.steps.count, 0)
            for step in chapter.steps {
                XCTAssertGreaterThan(step.scene.items.count, 0)
                for lang in Self.languages {
                    XCTAssertNotEqual(SecutgPhoneLayout.pick(step.title, lang), "", "\(step.id)/\(lang)")
                    XCTAssertNotEqual(SecutgPhoneLayout.pick(step.body, lang), "", "\(step.id)/\(lang)")
                }
            }
        }
    }

    func testEveryStepDrawsInsideThePhoneInEveryLanguage() {
        for lang in Self.languages {
            for chapter in Self.guide.chapters {
                for step in chapter.steps {
                    let prims = SecutgPhoneLayout.layoutScene(step.scene, lang: lang, inputPlaceholder: "Message")
                    XCTAssertGreaterThan(prims.count, 4)
                    for prim in prims {
                        let where_ = "\(step.id)/\(lang)"
                        switch prim {
                        case let .rect(rect):
                            XCTAssertGreaterThanOrEqual(rect.x, 0, where_)
                            XCTAssertLessThanOrEqual(rect.x + rect.w, SecutgPhoneLayout.phoneWidth, where_)
                            XCTAssertLessThanOrEqual(rect.y + rect.h, SecutgPhoneLayout.phoneHeight, where_)
                        case let .text(text):
                            XCTAssertGreaterThanOrEqual(text.x, 0, where_)
                            XCTAssertLessThanOrEqual(text.x, SecutgPhoneLayout.phoneWidth, where_)
                            XCTAssertLessThanOrEqual(text.y, SecutgPhoneLayout.phoneHeight, where_)
                            XCTAssertNotEqual(text.text, "", where_)
                        case let .circle(circle):
                            XCTAssertGreaterThanOrEqual(circle.cx - circle.r, 0, where_)
                            XCTAssertLessThanOrEqual(circle.cx + circle.r, SecutgPhoneLayout.phoneWidth, where_)
                            XCTAssertLessThanOrEqual(circle.cy + circle.r, SecutgPhoneLayout.phoneHeight, where_)
                        case let .line(line):
                            XCTAssertLessThanOrEqual(max(line.x1, line.x2), SecutgPhoneLayout.phoneWidth, where_)
                            XCTAssertLessThanOrEqual(max(line.y1, line.y2), SecutgPhoneLayout.phoneHeight, where_)
                        }
                    }
                }
            }
        }
    }

    func testAnOverlaySceneDimsTheScreenAndKeepsItsPanelOnTopOfTheDim() throws {
        let sheetStep = try XCTUnwrap(Self.guide.chapters[0].steps.first(where: { $0.scene.sheet == "sheet" }))
        let prims = SecutgPhoneLayout.layoutScene(sheetStep.scene, lang: "zh-Hans", inputPlaceholder: "Message")
        let dimIndex = try XCTUnwrap(prims.firstIndex(where: {
            if case let .rect(rect) = $0 { return rect.opacity == 0.45 }
            return false
        }))
        XCTAssertGreaterThan(dimIndex, 0)
        let panelIndex = try XCTUnwrap(prims.indices.first(where: { index in
            guard index > dimIndex, case let .rect(rect) = prims[index] else { return false }
            return rect.stroke == .border
        }))
        XCTAssertGreaterThan(panelIndex, dimIndex)
    }

    /// Every scene the content file declares must be drawable: an unknown `k` would silently vanish from the picture.
    func testEverySceneItemKindIsOneTheLayoutKnows() {
        let known: Set<String> = ["in", "out", "service", "body", "row", "item", "button", "code", "qr", "input"]
        for chapter in Self.guide.chapters {
            for step in chapter.steps {
                for item in step.scene.items {
                    XCTAssertTrue(known.contains(item.k), "\(step.id): unknown item kind \(item.k)")
                }
            }
        }
    }
}
