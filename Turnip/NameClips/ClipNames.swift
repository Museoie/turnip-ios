import Foundation

/// The naming rules a clip's names follow wherever they are given (`docs/PROFILE_DESIGN.md` §4):
/// on Name Clips before the save, and on the Profile's screens after it.
extension Array where Element == ClipName {
    /// Adds a trick name, trimmed. A blank name, or one already here in any case, changes nothing.
    /// Returns whether the name was added.
    @discardableResult
    mutating func addName(_ name: String, origin: LabelOrigin) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = TrickVocabulary.normalized(trimmed)
        guard !contains(where: { TrickVocabulary.normalized($0.name) == key }) else { return false }
        append(ClipName(name: trimmed, origin: origin))
        return true
    }

    /// "Did you mean": puts the vocabulary's spelling in `name`'s place, as a pick, dropping another
    /// name that already spells it. Returns whether `name` was here to replace.
    @discardableResult
    mutating func replaceName(_ name: ClipName, with canonical: String) -> Bool {
        guard let position = firstIndex(of: name) else { return false }
        let key = TrickVocabulary.normalized(canonical)
        removeAll { $0 != name && TrickVocabulary.normalized($0.name) == key }
        let slot = firstIndex(of: name) ?? position
        self[slot] = ClipName(name: canonical, origin: .vocabulary)
        return true
    }
}
