import XCTest
@testable import Turnip

/// The user's own synonyms over the farm's vocabulary (`docs/PROFILE_DESIGN.md` §4.5): what they
/// group, what they leave the farm's, and what goes to the farm as a suggestion.
final class TrickSynonymTests: XCTestCase {
    private let seed = TrickVocabulary.seed

    private func synonym(_ name: String, _ sameAs: String) -> TrickSynonym {
        TrickSynonym(name: name, sameAs: sameAs)
    }

    // MARK: - Merging

    /// Two of the farm's tricks become one: every spelling of the merged trick resolves to the kept
    /// one, and the farm still knows each of them.
    func testMergingTwoOfTheFarmsTricksMovesEverySpelling() {
        let merged = seed.merging([synonym("cork", "cartfull")])
        XCTAssertEqual(merged.canonicalName(for: "Corkscrew"), "cartfull")
        XCTAssertEqual(merged.canonicalName(for: "cork"), "cartfull")
        XCTAssertEqual(merged.names(matching: ""), ["cartfull", "gainer", "hook", "scoot"])
        XCTAssertTrue(merged.knows("corkscrew"))
        XCTAssertTrue(merged.personalSpellings.isEmpty)
        XCTAssertEqual(merged.taxonomyVersion, seed.taxonomyVersion)
    }

    /// A name the farm lacks joins the trick on this device only: it groups, but it isn't a name
    /// the farm accepts, and a pick of it is typed.
    func testANameTheFarmLacksGroupsButStaysTheUsersOwn() {
        let merged = seed.merging([synonym("Cartwheel Full Twist", "cartfull")])
        XCTAssertEqual(merged.canonicalName(for: "cartwheel  full twist"), "cartfull")
        XCTAssertFalse(merged.knows("cartwheel full twist"))
        XCTAssertTrue(merged.knows("cartfull"))
        XCTAssertTrue(merged.isPersonal("CARTWHEEL FULL TWIST"))
        XCTAssertEqual(NamingSuggestions.origin(of: "cartwheel full twist", vocabulary: merged), .typed)
        XCTAssertEqual(NamingSuggestions.origin(of: "cartfull", vocabulary: merged), .vocabulary)
        XCTAssertEqual(merged.names(matching: "wheel"), ["cartfull"])
    }

    /// Keeping the user's own name makes it the trick's canonical name here, and the farm's names
    /// its spellings. "Did you mean" never offers it: the replacement counts as a farm pick.
    func testKeepingTheUsersOwnNameNeverOffersItAsACorrection() {
        let merged = seed.merging([synonym("cartfull", "cartwheel full twist")])
        XCTAssertEqual(merged.canonicalName(for: "cartfull"), "cartwheel full twist")
        XCTAssertTrue(merged.knows("cartfull"))
        XCTAssertFalse(merged.knows("cartwheel full twist"))
        XCTAssertEqual(NamingSuggestions.origin(of: "cartwheel full twist", vocabulary: merged), .typed)
        XCTAssertNil(merged.suggestedCorrection(for: "cartfull"))
        XCTAssertNil(merged.suggestedCorrection(for: "cartwheel ful twist"))
        XCTAssertEqual(merged.suggestedCorrection(for: "corkscrew"), "cork")
    }

    /// Synonyms apply in order, so a chain puts all three names in one trick.
    func testSynonymsChain() {
        let merged = seed.merging([synonym("raiz", "gainer"), synonym("gainer", "hook")])
        XCTAssertEqual(merged.canonicalName(for: "raiz"), "hook")
        XCTAssertEqual(merged.canonicalName(for: "gainer"), "hook")
        XCTAssertEqual(TrickNaming.tricks(for: "raiz - gainer", vocabulary: merged).map(\.name), ["hook"])
    }

    /// Names already one trick, as once the farm has merged them too, or one name twice, change
    /// nothing.
    func testASynonymTheVocabularyAlreadyHasChangesNothing() {
        XCTAssertEqual(seed.merging([synonym("corkscrew", "cork")]), seed)
        XCTAssertEqual(seed.merging([synonym("Raiz", "raiz ")]), seed)
        XCTAssertEqual(seed.merging([synonym(" ", "cork")]), seed)
    }

    // MARK: - The farm's request

    func testSynonymBatchesKeepWhatTheFarmAccepts() {
        let long = String(repeating: "x", count: 65)
        let batch = SynonymCandidates.batch([
            synonym(" Cartwheel Full Twist ", "cartfull"),
            synonym("cartwheel full twist", "CARTFULL"),
            synonym("raiz", "Raiz"),
            synonym("", "cork"),
            synonym(long, "cork"),
            synonym("cartfull", "cartwheel full twist")
        ])
        XCTAssertEqual(batch, [
            synonym("Cartwheel Full Twist", "cartfull"),
            synonym("cartfull", "cartwheel full twist")
        ])
        let many = (0..<25).map { synonym("trick \($0)", "cork") }
        XCTAssertEqual(SynonymCandidates.batch(many).count, SynonymCandidates.maximumCount)
    }

    // MARK: - Suggestions

    private func ordered(
        draft: String = "", given: [ClipName] = [], used: [String] = [], belowBar: [String] = [],
        recent: [String] = [], vocabulary: TrickVocabulary = .seed
    ) -> [String] {
        NamingSuggestions.ordered(
            draft: draft, given: given,
            suggested: PersonalSuggestions(used: used, belowBar: belowBar).withRecent(recent),
            vocabulary: vocabulary)
    }

    /// The user's recent names follow the video's own and the model's below-bar names, and lead the
    /// rest of the vocabulary.
    func testRecentNamesFollowTheVideosAndLeadTheVocabulary() {
        XCTAssertEqual(
            ordered(used: ["hook"], belowBar: ["gainer"], recent: ["raiz", "hook", "scoot"]),
            ["hook", "gainer", "raiz", "scoot", "cartfull", "cork"])
    }

    func testRecentNamesFollowTheDraft() {
        XCTAssertEqual(ordered(draft: "ra", recent: ["raiz", "scoot"]), ["raiz"])
    }

    func testARecentNameTheClipHasIsLeftOut() {
        XCTAssertEqual(
            ordered(given: [ClipName(name: "Raiz", origin: .typed)], recent: ["raiz", "gainer"]),
            ["gainer", "cartfull", "cork", "hook", "scoot"])
    }
}

/// `VocabularyStore`'s synonyms: kept across launches, laid over every vocabulary it adopts, and
/// sent to the farm while the user contributes.
@MainActor
final class VocabularyStoreSynonymTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-synonyms-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var synonymsURL: URL { directory.appendingPathComponent("synonyms.json") }
    private var cacheURL: URL { directory.appendingPathComponent("vocabulary.json") }

    private func store(_ farm: ScriptedFarm? = nil) -> VocabularyStore {
        VocabularyStore(client: farm?.client, cacheURL: cacheURL, synonymsURL: synonymsURL)
    }

    private func account(_ farm: ScriptedFarm, signedIn: Bool = true) -> FarmAccount {
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.agreeAndRecordOnFarm()
        if !signedIn { credentials.signedOut() }
        return FarmAccount(client: farm.client, credentials: credentials)
    }

    private let fullTwist = TrickSynonym(name: "cartwheel full twist", sameAs: "cartfull")

    func testASynonymGroupsAtOnceAndSurvivesARelaunch() {
        let vocabulary = store()
        vocabulary.addSynonym(fullTwist, suggest: false)
        XCTAssertEqual(vocabulary.current.canonicalName(for: "cartwheel full twist"), "cartfull")
        XCTAssertNil(vocabulary.farm.canonicalName(for: "cartwheel full twist"), "the farm's own stays as fetched")
        XCTAssertEqual(
            vocabulary.synonyms(groupedUnder: Trick(key: "cartfull", name: "cartfull")), [fullTwist])

        let relaunched = store()
        XCTAssertEqual(relaunched.synonyms, [fullTwist])
        XCTAssertEqual(relaunched.current, vocabulary.current)

        relaunched.removeSynonym(fullTwist)
        XCTAssertNil(relaunched.current.canonicalName(for: "cartwheel full twist"))
        XCTAssertEqual(store().synonyms, [])
    }

    /// Names the vocabulary already has as one trick add no synonym.
    func testASynonymAlreadyInTheVocabularyIsNotKept() {
        let vocabulary = store()
        vocabulary.addSynonym(TrickSynonym(name: "corkscrew", sameAs: "cork"), suggest: true)
        XCTAssertEqual(vocabulary.synonyms, [])
    }

    /// A newer vocabulary from the farm comes in under the user's synonyms.
    func testANewerVocabularyKeepsTheUsersSynonyms() async {
        let newer = #"{"taxonomy_version":4,"vocabulary":[{"canonical":"cartfull","aliases":["cartfull"]},"#
            + #"{"canonical":"raiz","aliases":["raiz"]}]}"#
        let farm = ScriptedFarm([.init(status: 200, body: newer)])
        let vocabulary = store(farm)
        vocabulary.addSynonym(fullTwist, suggest: false)
        await vocabulary.refreshIfStale()
        XCTAssertEqual(vocabulary.farm.taxonomyVersion, 4)
        XCTAssertEqual(vocabulary.current.canonicalName(for: "cartwheel full twist"), "cartfull")
        XCTAssertEqual(vocabulary.current.canonicalName(for: "raiz"), "raiz")
    }

    /// A synonym made while contributing goes to the farm once, with the session.
    func testASuggestedSynonymIsSentOnce() async throws {
        let farm = ScriptedFarm([.init(status: 202, body: "")])
        let vocabulary = store(farm)
        vocabulary.addSynonym(fullTwist, suggest: true)
        await vocabulary.sendSynonyms(account: account(farm), contributes: true)
        await vocabulary.sendSynonyms(account: account(farm), contributes: true)

        XCTAssertEqual(farm.calls, ["POST /api/labels/synonyms"])
        let request = try XCTUnwrap(farm.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(
            body["synonyms"] as? [[String: String]], [["name": "cartwheel full twist", "same_as": "cartfull"]])
    }

    /// One made while not contributing stays on the device.
    func testASynonymNotSuggestedIsNeverSent() async {
        let farm = ScriptedFarm([])
        let vocabulary = store(farm)
        vocabulary.addSynonym(fullTwist, suggest: false)
        await vocabulary.sendSynonyms(account: account(farm), contributes: true)
        XCTAssertEqual(farm.calls, [])
    }

    /// Signed out, the suggestion waits; with contributing turned off, it is dropped.
    func testAWaitingSuggestionWaitsForASignInAndGoesWithContributing() async {
        let farm = ScriptedFarm([])
        let vocabulary = store(farm)
        vocabulary.addSynonym(fullTwist, suggest: true)
        await vocabulary.sendSynonyms(account: account(farm, signedIn: false), contributes: true)
        XCTAssertEqual(farm.calls, [])

        await vocabulary.sendSynonyms(account: account(farm), contributes: false)
        await store(farm).sendSynonyms(account: account(farm), contributes: true)
        XCTAssertEqual(farm.calls, [], "turning contributing off dropped the waiting suggestion")
        XCTAssertEqual(store(farm).synonyms, [fullTwist], "the synonym itself stays")
    }

    /// An unreachable farm keeps the suggestion for later, also across a relaunch; a refusal drops
    /// it; a dead session signs out and keeps it.
    func testAFailedSendKeepsTheSuggestionUnlessTheFarmRefusedIt() async {
        let farm = ScriptedFarm([])
        let vocabulary = store(farm)
        vocabulary.addSynonym(fullTwist, suggest: true)
        await vocabulary.sendSynonyms(account: account(farm), contributes: true)

        let unauthenticated = #"{"error":{"code":"UNAUTHENTICATED","message":"no"}}"#
        farm.script([.init(status: 401, body: unauthenticated)])
        let signedIn = account(farm)
        await store(farm).sendSynonyms(account: signedIn, contributes: true)
        XCTAssertFalse(signedIn.isSignedIn)

        let refused = #"{"error":{"code":"VALIDATION_ERROR","message":"no"}}"#
        farm.script([.init(status: 422, body: refused)])
        await store(farm).sendSynonyms(account: account(farm), contributes: true)
        await store(farm).sendSynonyms(account: account(farm), contributes: true)
        XCTAssertEqual(farm.calls, Array(repeating: "POST /api/labels/synonyms", count: 3))
    }
}
