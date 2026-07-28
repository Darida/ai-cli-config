import type { EndpointEntry } from "./image-cost-estimate";

// Isolated network layer shared by list-image-models.ts and
// pick-image-model.ts — neither duplicates fetch logic, both work off the
// same live OpenRouter Images API model/endpoint data.
export const IMAGES_MODELS_URL = "https://openrouter.ai/api/v1/images/models";

export interface ModelListEntry {
  id: string;
  name: string;
}

export async function fetchModelList(): Promise<ModelListEntry[]> {
  const response = await fetch(IMAGES_MODELS_URL);
  if (!response.ok) {
    throw new Error(`Failed to list models: ${response.status} ${response.statusText}`);
  }
  return (await response.json()).data;
}

export async function fetchEndpoints(modelId: string): Promise<EndpointEntry[]> {
  const response = await fetch(`${IMAGES_MODELS_URL}/${modelId}/endpoints`);
  if (!response.ok) {
    throw new Error(`Failed to fetch endpoints for ${modelId}: ${response.status} ${response.statusText}`);
  }
  return (await response.json()).endpoints;
}
