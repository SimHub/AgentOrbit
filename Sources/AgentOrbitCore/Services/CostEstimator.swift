import Foundation

public struct CostEstimate: Sendable, Equatable {
    public let amountUSD: Double
    public let isEstimated: Bool

    public var formatted: String {
        let prefix = isEstimated ? "~" : ""
        if amountUSD < 0.01 {
            return "\(prefix)<$0.01"
        }
        if amountUSD < 10.0 {
            return String(format: "%@$%.2f", prefix, amountUSD)
        }
        return String(format: "%@$%.1f", prefix, amountUSD)
    }
}

public enum CostEstimator {
    private struct Rates {
        let inputPerMillion: Double
        let cachedPerMillion: Double
        let outputPerMillion: Double
    }

    public static func estimate(usage: UsageMetrics, modelName: String) -> CostEstimate? {
        if let recorded = usage.recordedCostUSD, recorded > 0 {
            return CostEstimate(amountUSD: recorded, isEstimated: false)
        }

        let inp = Double(usage.inputTokens ?? 0)
        let cache = Double(usage.cacheReadTokens ?? 0)
        let out = Double(usage.outputTokens ?? 0)
        let rates = rates(for: modelName)

        if inp > 0 || cache > 0 || out > 0 {
            // If input + cache + output exceeds sessionTotalTokens, cache is a subset of input (OpenAI style).
            let total = Double(usage.sessionTotalTokens ?? 0)
            let uncachedInput: Double
            if total > 0 && (inp + cache + out) > total * 1.05 {
                uncachedInput = max(0, inp - cache)
            } else {
                uncachedInput = inp
            }
            let usd = (uncachedInput * rates.inputPerMillion
                + cache * rates.cachedPerMillion
                + out * rates.outputPerMillion) / 1_000_000.0
            return usd > 0 ? CostEstimate(amountUSD: usd, isEstimated: true) : nil
        }

        if let total = usage.sessionTotalTokens, total > 0 {
            // Rough blended estimate when only total tokens are available
            let blendedPerMillion = (rates.inputPerMillion * 0.7) + (rates.outputPerMillion * 0.3)
            let usd = Double(total) * blendedPerMillion / 1_000_000.0
            return usd > 0 ? CostEstimate(amountUSD: usd, isEstimated: true) : nil
        }

        return nil
    }

    private static func rates(for modelName: String) -> Rates {
        let lower = modelName.lowercased()
        if lower.contains("opus") {
            return Rates(inputPerMillion: 15.0, cachedPerMillion: 1.50, outputPerMillion: 75.0)
        }
        if lower.contains("sonnet") {
            return Rates(inputPerMillion: 3.0, cachedPerMillion: 0.30, outputPerMillion: 15.0)
        }
        if lower.contains("haiku") {
            return Rates(inputPerMillion: 0.80, cachedPerMillion: 0.08, outputPerMillion: 4.0)
        }
        if lower.contains("gemini") {
            if lower.contains("flash") || lower.contains("argon") {
                return Rates(inputPerMillion: 0.15, cachedPerMillion: 0.0375, outputPerMillion: 0.60)
            }
            return Rates(inputPerMillion: 1.25, cachedPerMillion: 0.31, outputPerMillion: 10.0)
        }
        if lower.contains("mini") || lower.contains("nano") {
            return Rates(inputPerMillion: 0.40, cachedPerMillion: 0.10, outputPerMillion: 1.60)
        }
        if lower.contains("gpt") || lower.contains("codex") || lower.contains("o3") || lower.contains("o4") {
            return Rates(inputPerMillion: 2.0, cachedPerMillion: 0.50, outputPerMillion: 8.0)
        }
        return Rates(inputPerMillion: 2.0, cachedPerMillion: 0.40, outputPerMillion: 8.0)
    }
}
