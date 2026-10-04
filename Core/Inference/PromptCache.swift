import Foundation

/// One piece of a prompt as the model sees it: a run of text tokens, or an image or audio clip.
/// Media are identified by a hash of their bytes, so the same picture is recognised again
/// without comparing its pixels or encoding it a second time.
enum PromptSegment: Equatable, Sendable {
    case text([Int32])
    case media(id: String, tokens: Int, positions: Int)

    /// KV-cache positions the segment occupies. Text uses one per token; an image can use fewer
    /// positions than tokens, which is why the two are tracked separately.
    var positionCount: Int {
        switch self {
        case let .text(tokens): return tokens.count
        case let .media(_, _, positions): return positions
        }
    }

    var tokenCount: Int {
        switch self {
        case let .text(tokens): return tokens.count
        case let .media(_, tokens, _): return tokens
        }
    }
}

/// Remembers what the model has already computed, so the next request only pays for what is new.
///
/// The server is stateless: a client sends the whole conversation every time. When that conversation
/// starts with what was sent last time (plus the model's reply), the KV cache of that part is still
/// valid, and only the tail needs to be evaluated. This type decides how much can be kept.
struct PromptCache: Sendable {
    /// What the KV cache holds, in order: the previous prompt and then the tokens the model generated.
    private(set) var cached: [PromptSegment] = []

    var cachedPositions: Int { cached.reduce(0) { $0 + $1.positionCount } }

    /// How many positions of `incoming` are already in the cache, and where to resume.
    struct Reuse: Equatable, Sendable {
        /// KV-cache positions that can stay.
        let keptPositions: Int
        /// Index of the first segment that has to be evaluated, and the offset inside it when only
        /// the start of a text run matches.
        let resumeSegment: Int
        let resumeTokenOffset: Int
    }

    /// The longest common start of the cache and `incoming`. A media segment either matches fully
    /// (same hash) or not at all; a text run can match partway.
    func reuse(for incoming: [PromptSegment]) -> Reuse {
        var kept = 0
        for (index, segment) in incoming.enumerated() {
            guard index < cached.count else {
                return Reuse(keptPositions: kept, resumeSegment: index, resumeTokenOffset: 0)
            }
            switch (cached[index], segment) {
            case let (.text(old), .text(new)):
                let common = zip(old, new).prefix { $0 == $1 }.count
                kept += common
                if common == new.count, common == old.count {
                    continue
                }
                return Reuse(keptPositions: kept, resumeSegment: index, resumeTokenOffset: common)
            case let (.media(oldID, _, oldPositions), .media(newID, _, _)):
                if oldID == newID, !oldID.isEmpty {
                    kept += oldPositions
                    continue
                }
                return Reuse(keptPositions: kept, resumeSegment: index, resumeTokenOffset: 0)
            default:
                return Reuse(keptPositions: kept, resumeSegment: index, resumeTokenOffset: 0)
            }
        }
        // The whole incoming prompt is a prefix of the cache. The model needs a fresh logit for the
        // last token, so that one token is evaluated again.
        guard let last = incoming.last else { return Reuse(keptPositions: 0, resumeSegment: 0, resumeTokenOffset: 0) }
        switch last {
        case let .text(tokens) where !tokens.isEmpty:
            return Reuse(keptPositions: kept - 1, resumeSegment: incoming.count - 1, resumeTokenOffset: tokens.count - 1)
        default:
            // A media segment cannot be resumed from inside: evaluate all of it again.
            return Reuse(keptPositions: kept - last.positionCount, resumeSegment: incoming.count - 1, resumeTokenOffset: 0)
        }
    }

    /// Replaces the cache with the prompt that was just evaluated, followed by the generated tokens.
    mutating func store(prompt: [PromptSegment], generated: [Int32]) {
        cached = prompt
        guard !generated.isEmpty else { return }
        if case let .text(tail)? = cached.last {
            cached[cached.count - 1] = .text(tail + generated)
        } else {
            cached.append(.text(generated))
        }
    }

    /// Forget everything, for example when the model or the context size changes.
    mutating func reset() {
        cached = []
    }
}
