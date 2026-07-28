// Pure data — no logic belongs in this file. Shapes describing an
// OpenRouter Images API model/provider endpoint, as used across this
// package's scripts.

export interface ParamSpec {
  type: string;
  values?: string[];
  min?: number;
  max?: number;
}

export interface PricingLine {
  billable: string;
  unit: string;
  cost_usd: number;
  variant?: string;
}

// One candidate model×provider endpoint — what fetchModels() (clients/
// open-router.ts) returns a list of. supported_parameters/pricing are
// exactly as OpenRouter reported them, unconverted (see asset-adjuster.ts
// and clients/open-router.ts for where format conversion actually
// happens).
export interface Model {
  modelId: string;
  provider: string;
  supported_parameters?: Record<string, ParamSpec>;
  pricing: PricingLine[];
}
