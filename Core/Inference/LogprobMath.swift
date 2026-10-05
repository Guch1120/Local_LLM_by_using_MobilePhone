import Foundation

/// Turns the raw scores (logits) the model produced for one position into log-probabilities.
enum LogprobMath {
    /// The `count` most likely tokens as (token id, log-probability), best first, and the log-probability of `chosen`.
    /// Log-probabilities are logit minus the log of the sum of exp(logit), computed against the maximum so that
    /// large scores do not overflow.
    static func topLogprobs(logits: UnsafeBufferPointer<Float>, chosen: Int, count: Int) -> (top: [(id: Int, logprob: Double)], chosen: Double) {
        guard !logits.isEmpty else { return ([], -Double.infinity) }
        var maximum = -Float.infinity
        for value in logits where value > maximum { maximum = value }
        var sum = 0.0
        for value in logits { sum += Double(expf(value - maximum)) }
        let logSum = Double(maximum) + log(sum)

        // A small insertion list: count is tiny (a handful), the vocabulary is huge.
        var best: [(id: Int, logit: Float)] = []
        if count > 0 {
            best.reserveCapacity(count + 1)
            for (index, value) in logits.enumerated() {
                if best.count == count, value <= best[best.count - 1].logit { continue }
                var position = best.count
                while position > 0, best[position - 1].logit < value { position -= 1 }
                best.insert((index, value), at: position)
                if best.count > count { best.removeLast() }
            }
        }
        let chosenLogprob = chosen >= 0 && chosen < logits.count ? Double(logits[chosen]) - logSum : -Double.infinity
        return (best.map { ($0.id, Double($0.logit) - logSum) }, chosenLogprob)
    }
}
