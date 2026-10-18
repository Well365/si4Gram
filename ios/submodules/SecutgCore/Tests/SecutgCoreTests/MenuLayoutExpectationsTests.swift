import XCTest
@testable import SecutgCore

/// PLAN.md 3.49's shared, four-client contract: `Vectors/menu-layout-expectations.json` (generated and owned by
/// the Web client, `src/secutg/ui/actions.ts`) lists, for twelve-plus named chat states, exactly which canonical
/// ids each of the lock menu's five primary sections and "更多…"'s three sections hold, and which of those ids
/// render destructive.
///
/// `MenuLayout` never decides presence (every client's own per-state code still does that), so this test does
/// not reproduce each state's gating logic either. Instead, for every state it takes the exact ids the fixture
/// says are present — flattened out of their expected sections, in a deliberately SCRAMBLED order — and checks
/// that `MenuLayout.sections`/`moreSections` puts them back into precisely the fixture's section structure, and
/// that `MenuLayout.isDanger` agrees with the fixture's `danger` list for every id offered anywhere in the
/// state. That is the whole of what `MenuLayout` is responsible for, and the whole of what this test can hold it
/// to — a state whose real menu is missing or has an extra id is a bug in that client's own gating code, not in
/// this shared table, and `knownGaps` in the fixture documents the one state (`resetChat`) no state below
/// exercises because the Web client does not implement it at all.
final class MenuLayoutExpectationsTests: XCTestCase {
    private struct Fixture {
        let states: [String: State]
    }

    private struct State {
        let primary: [[MenuLayout.Id]]
        let more: [[MenuLayout.Id]]
        let danger: Set<MenuLayout.Id>
    }

    private static let fixture: Fixture = load()

    private static func load() -> Fixture {
        let json = Vectors.load("menu-layout-expectations")
        guard let states = json["states"] as? [String: [String: Any]] else {
            XCTFail("menu-layout-expectations.json: missing `states`")
            return Fixture(states: [:])
        }
        var out: [String: State] = [:]
        for (name, raw) in states {
            guard let primaryRaw = raw["primary"] as? [[String]], let moreRaw = raw["more"] as? [[String]],
                  let dangerRaw = raw["danger"] as? [String] else {
                XCTFail("menu-layout-expectations.json: state \(name) is missing primary/more/danger")
                continue
            }
            out[name] = State(
                primary: primaryRaw.map { $0.compactMap(MenuLayout.Id.init(rawValue:)) },
                more: moreRaw.map { $0.compactMap(MenuLayout.Id.init(rawValue:)) },
                danger: Set(dangerRaw.compactMap(MenuLayout.Id.init(rawValue:))))
        }
        return Fixture(states: out)
    }

    /// Flattens the fixture's own section lists into one list, deliberately not in the fixture's order: a
    /// caller's real id list comes from its own append order, not from pre-grouped sections, and this test
    /// should not accidentally pass just because it handed `MenuLayout` already-sorted input.
    private func scrambledIds(_ sections: [[MenuLayout.Id]]) -> [MenuLayout.Id] {
        // Reversed within each section and the sections interleaved back-to-front: not a random shuffle (this
        // must be deterministic), but nothing here matches the fixture's own order by construction.
        return sections.reversed().flatMap { $0.reversed() }
    }

    func testEveryStateReproducesItsFixtureLayout() throws {
        let states = Self.fixture.states
        XCTAssertFalse(states.isEmpty, "menu-layout-expectations.json produced no states — check the fixture loaded")
        for (name, state) in states {
            let primaryIds = scrambledIds(state.primary)
            let actualPrimary = MenuLayout.sections(primaryIds).map { $0.ids }
            let expectedPrimary = state.primary.filter { !$0.isEmpty }
            XCTAssertEqual(actualPrimary, expectedPrimary, "\(name): primary section layout mismatch")

            let moreIds = scrambledIds(state.more)
            let actualMore = MenuLayout.moreSections(moreIds).map { $0.ids }
            let expectedMore = state.more.filter { !$0.isEmpty }
            XCTAssertEqual(actualMore, expectedMore, "\(name): more section layout mismatch")

            let allIds = Set(primaryIds + moreIds)
            let actualDanger = allIds.filter(MenuLayout.isDanger)
            XCTAssertEqual(actualDanger, state.danger, "\(name): danger (red) set mismatch")
        }
    }

    /// Every id the fixture's `canonicalIds` names must have a place in `MenuLayout`'s own tables — the two
    /// tables (Web's JSON, this file's Swift) are meant to be the same contract written twice.
    func testCanonicalIdsAllHaveAPlace() {
        let json = Vectors.load("menu-layout-expectations")
        guard let canonical = json["canonicalIds"] as? [String: [String]] else {
            XCTFail("menu-layout-expectations.json: missing `canonicalIds`")
            return
        }
        for raw in (canonical["primary"] ?? []) {
            guard let id = MenuLayout.Id(rawValue: raw) else {
                XCTFail("canonicalIds.primary names \(raw), which MenuLayout.Id has no case for")
                continue
            }
            XCTAssertFalse(MenuLayout.sections([id]).isEmpty, "\(raw) has no section in MenuLayout.order")
        }
        for raw in (canonical["more"] ?? []) {
            guard let id = MenuLayout.Id(rawValue: raw) else {
                XCTFail("canonicalIds.more names \(raw), which MenuLayout.Id has no case for")
                continue
            }
            XCTAssertFalse(MenuLayout.moreSections([id]).isEmpty, "\(raw) has no section in MenuLayout.moreOrder")
        }
    }
}
