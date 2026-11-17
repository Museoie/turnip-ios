import Foundation

/// What Clip List's filters let through (`docs/UIUX.md` § "Clip List"): clips detection was at
/// least `minimumConfidence` sure of, of a person whose top matches `shirtColor`. A clip detection
/// didn't propose — one added by hand — passes both, since the user made it.
///
/// A filter only hides. A hidden clip is still the video's: loosening the filter brings it back,
/// and until then the grid, Name Clips and Save Clips leave it out. It isn't removed, so the
/// personal layer doesn't keep it as a dismissed proposal (`docs/PERSONALIZATION_DESIGN.md` §3):
/// another person's trick, hidden by colour, is still a trick.
struct ClipFilter: Equatable {
    /// The confidence a clip needs (`ClipListItem.confidence`); 0 lets every clip through.
    var minimumConfidence: Float = 0
    /// The top a clip's person has to wear, `nil` for any.
    var shirtColor: ShirtColorMatch?

    var isActive: Bool { minimumConfidence > 0 || shirtColor != nil }

    /// Whether `item` is shown. `torsoColor` is what reading its person's top found, `nil` until it
    /// has been read: an unread clip stays until its reading says otherwise, and one whose top
    /// couldn't be read — no frame shows the person's whole torso — has nothing to match.
    func admits(_ item: ClipListItem, torsoColor: TorsoColorReading?) -> Bool {
        guard let confidence = item.confidence else { return true }
        guard confidence >= minimumConfidence else { return false }
        guard let shirtColor, let torsoColor else { return true }
        return torsoColor.color.map(shirtColor.matches) ?? false
    }
}

/// What reading a clip's person's top found (`TorsoColorReader`): its colour, or `nil` when no
/// frame of the clip shows their whole torso.
struct TorsoColorReading: Equatable {
    let color: LabColor?
}

/// The top Clip List keeps the clips of: a colour picked by hand, or the one read from clips the
/// user picked.
struct ShirtColorMatch: Equatable {
    let color: LabColor
    /// How far (`LabColor.distance(to:)`) a top can be from `color` and still match.
    let tolerance: Float
    /// The clips `color` was read from; empty when it was picked by hand.
    let sourceClipIDs: Set<UUID>

    /// How far a top can be from the colour and still match, unless the clips it was read from
    /// differ by more. Worked out from example colours, not measured on labelled footage: a red,
    /// blue or green shirt 40% darker in shade sits 23-25 from itself in sun, while neighbouring
    /// colours sit further apart — navy from black 27, red from orange 34, red from pink 36.
    static let defaultTolerance: Float = 24

    /// A colour picked by hand.
    init(picked color: LabColor) {
        self.color = color
        tolerance = Self.defaultTolerance
        sourceClipIDs = []
    }

    /// The colour read from `sources`, each clip's top by its id: their median, matching at least
    /// as loosely as `defaultTolerance` and loosely enough that every source matches, so a clip the
    /// user picked as theirs never hides. Picking a clip in shade and one in sun widens the match
    /// to the tops in between. `nil` for no sources.
    init?(readFrom sources: [UUID: LabColor]) {
        guard let color = LabColor.median(of: Array(sources.values)) else { return nil }
        self.color = color
        tolerance = sources.values.map { $0.distance(to: color) }.reduce(Self.defaultTolerance, max)
        sourceClipIDs = Set(sources.keys)
    }

    func matches(_ top: LabColor) -> Bool {
        top.distance(to: color) <= tolerance
    }
}
