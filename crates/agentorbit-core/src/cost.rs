use crate::models::UsageMetrics;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CostEstimate {
    pub amount_usd: f64,
    pub is_estimated: bool,
}

impl CostEstimate {
    pub fn formatted(&self) -> String {
        let prefix = if self.is_estimated { "~" } else { "" };
        if self.amount_usd < 0.01 {
            format!("{prefix}<$0.01")
        } else if self.amount_usd < 10.0 {
            format!("{prefix}${:.2}", self.amount_usd)
        } else {
            format!("{prefix}${:.1}", self.amount_usd)
        }
    }
}

struct ModelRates {
    input_per_million: f64,
    cached_per_million: f64,
    output_per_million: f64,
}

pub fn estimate_cost(usage: &UsageMetrics, model_name: &str) -> Option<CostEstimate> {
    if let Some(recorded) = usage.recorded_cost_usd {
        if recorded > 0.0 {
            return Some(CostEstimate {
                amount_usd: recorded,
                is_estimated: false,
            });
        }
    }

    let inp = usage.input_tokens.unwrap_or(0) as f64;
    let cache = usage.cache_read_tokens.unwrap_or(0) as f64;
    let out = usage.output_tokens.unwrap_or(0) as f64;
    let rates = rates_for(model_name);

    if inp > 0.0 || cache > 0.0 || out > 0.0 {
        let total = usage.session_total_tokens.unwrap_or(0) as f64;
        let uncached_input = if total > 0.0 && (inp + cache + out) > total * 1.05 {
            (inp - cache).max(0.0)
        } else {
            inp
        };
        let usd = (uncached_input * rates.input_per_million
            + cache * rates.cached_per_million
            + out * rates.output_per_million)
            / 1_000_000.0;
        return (usd > 0.0).then_some(CostEstimate {
            amount_usd: usd,
            is_estimated: true,
        });
    }

    if let Some(total) = usage.session_total_tokens {
        if total > 0 {
            let blended = (rates.input_per_million * 0.7) + (rates.output_per_million * 0.3);
            let usd = (total as f64) * blended / 1_000_000.0;
            return (usd > 0.0).then_some(CostEstimate {
                amount_usd: usd,
                is_estimated: true,
            });
        }
    }

    None
}

fn rates_for(model_name: &str) -> ModelRates {
    let lower = model_name.to_lowercase();
    if lower.contains("opus") {
        return ModelRates {
            input_per_million: 15.0,
            cached_per_million: 1.50,
            output_per_million: 75.0,
        };
    }
    if lower.contains("sonnet") {
        return ModelRates {
            input_per_million: 3.0,
            cached_per_million: 0.30,
            output_per_million: 15.0,
        };
    }
    if lower.contains("haiku") {
        return ModelRates {
            input_per_million: 0.80,
            cached_per_million: 0.08,
            output_per_million: 4.0,
        };
    }
    if lower.contains("gemini") {
        if lower.contains("flash") || lower.contains("argon") {
            return ModelRates {
                input_per_million: 0.15,
                cached_per_million: 0.0375,
                output_per_million: 0.60,
            };
        }
        return ModelRates {
            input_per_million: 1.25,
            cached_per_million: 0.31,
            output_per_million: 10.0,
        };
    }
    if lower.contains("mini") || lower.contains("nano") {
        return ModelRates {
            input_per_million: 0.40,
            cached_per_million: 0.10,
            output_per_million: 1.60,
        };
    }
    if lower.contains("gpt")
        || lower.contains("codex")
        || lower.contains("o3")
        || lower.contains("o4")
    {
        return ModelRates {
            input_per_million: 2.0,
            cached_per_million: 0.50,
            output_per_million: 8.0,
        };
    }
    ModelRates {
        input_per_million: 2.0,
        cached_per_million: 0.40,
        output_per_million: 8.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_recorded_cost_when_present() {
        let usage = UsageMetrics {
            recorded_cost_usd: Some(0.42),
            input_tokens: Some(100_000),
            ..Default::default()
        };
        let est = estimate_cost(&usage, "claude-sonnet-4").unwrap();
        assert!(!est.is_estimated);
        assert_eq!(est.formatted(), "$0.42");
    }

    #[test]
    fn estimates_openai_cached_subset_correctly() {
        let usage = UsageMetrics {
            session_total_tokens: Some(1_050_000),
            input_tokens: Some(1_000_000),
            cache_read_tokens: Some(800_000),
            output_tokens: Some(50_000),
            ..Default::default()
        };
        let est = estimate_cost(&usage, "gpt-5.3-codex").unwrap();
        assert!(est.is_estimated);
        // uncached = 200k ($0.40) + cache 800k ($0.40) + out 50k ($0.40) = $1.20
        assert!((est.amount_usd - 1.20).abs() < 1e-6);
        assert_eq!(est.formatted(), "~$1.20");
    }
}
