import Foundation

/// Ranking for the window search.
///
/// The query is split on spaces and every word has to match on its own. A word normally matches as
/// a plain substring; only if that fails is a gapped match considered, and then only a tight one.
/// That ordering matters: a pure subsequence search will happily spell "google" out of single
/// letters scattered across an unrelated title, which is never what the person typing it meant.
enum FuzzyMatch {
    private static let separators = Set<Character>(
        [" ", "-", "_", ".", "/", ":", "—", "–", "(", "[", "|", ",", "'"]
    )
    private static let substringScore = 100
    private static let wordStartBonus = 25
    /// How many characters a gapped match may skip before it stops looking deliberate.
    private static let maxGappedSlack = 3

    /// Score for `query` against `candidate`, or nil when the candidate does not match.
    /// Higher is better; an empty query matches everything with a score of zero.
    static func score(_ query: String, in candidate: String) -> Int? {
        let terms = query.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return 0 }

        let haystack = Array(candidate.lowercased())
        var total = 0
        for term in terms {
            guard let score = scoreTerm(Array(term.lowercased()), in: haystack) else { return nil }
            total += score
        }
        // Among equally good matches, prefer the shorter title.
        return total - haystack.count / 20
    }

    private static func scoreTerm(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty else { return 0 }

        if let index = firstIndex(of: needle, in: haystack) {
            var score = substringScore - min(index, 40)
            if isWordStart(index, in: haystack) { score += wordStartBonus }
            return score
        }
        return gappedScore(needle, in: haystack)
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    private static func isWordStart(_ index: Int, in haystack: [Character]) -> Bool {
        index == 0 || separators.contains(haystack[index - 1])
    }

    /// A subsequence match that tolerates a few skipped characters — enough for a typo or a dropped
    /// letter, not enough to assemble the word out of an entire sentence.
    private static func gappedScore(_ needle: [Character], in haystack: [Character]) -> Int? {
        var needleIndex = 0
        var firstMatch: Int?
        var lastMatch = 0
        var score = 0

        for (index, character) in haystack.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }
            if firstMatch == nil {
                firstMatch = index
                if isWordStart(index, in: haystack) { score += wordStartBonus }
            } else if index == lastMatch + 1 {
                score += 4
            }
            lastMatch = index
            needleIndex += 1
        }

        guard needleIndex == needle.count, let first = firstMatch else { return nil }
        let span = lastMatch - first + 1
        guard span <= needle.count + maxGappedSlack else { return nil }
        return score - min(first, 20)
    }
}
