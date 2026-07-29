---
name: image-prompting-guide
description: Comprehensive rules, prompt structure formulas, best practices, and good/bad examples for writing prompts for generative image AI models (Imagen 3, Flux, Midjourney, DALL-E 3).
---

# Generative Image AI Prompting Guide

This guide provides actionable rules, structural formulas, best practices, and real-world good/bad examples for crafting effective prompts for generative image AI models (e.g., Google Imagen 3, Black Forest Labs Flux, Midjourney, DALL-E 3).

---

## 1. The Modular Prompt Formula

An effective image prompt is structured into clear, descriptive modules. Order matters: place the most important subject and style elements at the beginning of the prompt.

$$\text{Prompt} = \text{Subject} + \text{Action/Context} + \text{Medium/Style} + \text{Lighting/Mood} + \text{Camera/Composition}$$

### Core Modules Breakdown

1. **Subject**: Who or what is the focus? Be concrete. (e.g., *"a 60-year-old fisherman with a weathered face"* instead of *"a man"*).
2. **Action & Context**: What is happening and where? (e.g., *"mending a hemp fishing net inside a sunlit wooden boathouse"*).
3. **Medium & Art Style**: What is the visual technique? (e.g., *"cinematic 35mm film photography"*, *"oil painting on canvas"*, *"isometric 3D render"*, *"vector illustration"*).
4. **Lighting & Atmosphere**: How is the scene illuminated? (e.g., *"warm golden hour rim light"*, *"harsh neon glow"*, *"soft diffused window light"*).
5. **Camera & Composition**: How is the frame shot? (e.g., *"close-up macro shot"*, *"wide establishing angle"*, *"shallow depth of field with creamy bokeh"*).

---

## 2. Core Prompting Rules & Best Practices

### Rule 1: Use Positive Instructions
Focus on describing **what you want to see** rather than what to exclude. Most diffusion and transformer image models struggle with negation in the main prompt (e.g., *"a forest with no trees"* often renders extra trees). Use dedicated negative prompt fields if supported by your provider.

### Rule 2: Specificity Over Vague Quality Buzzwords
Avoid empty hype words like *"cool"*, *"beautiful"*, *"photorealistic 8k ultra detailed masterpiece"*. Modern models ignore or misinterpret tag-soup. Instead, describe the actual visual details that imply quality:
- Instead of *"beautiful lighting"*, write: *"soft volumetric light rays piercing through morning mist"*.
- Instead of *"high quality fabric"*, write: *"heavy woven tweed jacket with visible wool texture and brass buttons"*.

### Rule 3: Natural Language Coherence
Write coherent phrases or descriptive sentences. Avoid disconnected tag lists (e.g., `man, hat, standing, 8k, trending on artstation`). Modern models (Imagen 3, DALL-E 3, Flux) are trained on natural language captions and follow full sentences much better than comma-separated tag lists.

### Rule 4: Explicit Background & Edge Isolation for Assets
When generating UI icons, game sprites, or isolated objects:
- Explicitly declare the background type: *"isolated on a solid dark gray background"* or *"on a flat chroma-key magenta (#FF00FF) background"*.
- Specify clean framing: *"fully contained within the frame with a 20% margin around all edges"*.

---

## 3. Good vs. Bad Prompt Examples

### Example 1: Character / Creature Asset

- **❌ Bad Prompt:**
  > `cool dragon fighting`
  - *Why it fails:* Vague subject, no medium, no lighting, no composition. Output will be a generic, low-detail mashup.

- **✅ Good Prompt:**
  > `A majestic red-scaled dragon perched atop a jagged obsidian cliff, breathing a small plume of embers. Fantasy digital illustration style, dramatic thunderstorm sky in the background, sharp rim lighting highlighting the scales, wide-angle shot, highly detailed wing membranes.`
  - *Why it succeeds:* Specific subject features, clear action/setting, explicit medium, dramatic lighting, and concrete composition.

---

### Example 2: Environmental / Game Scene

- **❌ Bad Prompt:**
  > `cyberpunk city 8k ultra realistic high quality trending on artstation`
  - *Why it fails:* Relies entirely on quality buzzwords and generic tags. Produces noisy, cluttered images with inconsistent architecture.

- **✅ Good Prompt:**
  > `A rain-slicked alleyway in a futuristic cyberpunk city at night. Towering skyscrapers with glowing magenta and cyan neon signs reflected in water puddles on the asphalt. Cinematic film photography, shot on 35mm lens, shallow depth of field, steam rising from street grates.`
  - *Why it succeeds:* Describes specific environmental elements (rain-slicked, neon signs, water puddles, steam), exact color palette (magenta and cyan), and precise camera/film style.

---

### Example 3: Isolated Object / Game Icon

- **❌ Bad Prompt:**
  > `magic potion bottle no background`
  - *Why it fails:* Uses negative phrasing ("no background") in the main prompt, which models often misinterpret or ignore, rendering a kitchen background or table.

- **✅ Good Prompt:**
  > `A glowing ornate glass potion bottle filled with swirling violet liquid, topped with an antique bronze stopper. Game asset style, clean 3D render, isolated on a flat solid neutral gray background, centered framing with margin around edges, soft studio key light.`
  - *Why it succeeds:* Positive framing for isolation, clear asset description, defined material properties (ornate glass, bronze stopper), and studio lighting.

---

### Example 4: Photorealistic Portrait

- **❌ Bad Prompt:**
  > `beautiful woman portrait photo`
  - *Why it fails:* Lacks lighting, depth, age, expression, clothing, or camera parameters. Yields an artificial, plastic-looking face.

- **✅ Good Prompt:**
  > `A candid close-up portrait of a 30-year-old female architect with subtle freckles and dark hair, wearing a beige linen blazer. Soft natural window lighting coming from the side, shallow depth of field with a blurred architectural studio background, sharp focus on the eyes, neutral color tones.`
  - *Why it succeeds:* Realistic human descriptors (age, freckles, clothing), natural lighting source, real-world camera depth of field, and clean background context.

---

## 4. Quick Reference Checklist

Before sending a prompt to an image generation model, check:

1. [ ] **Subject**: Is the main subject clearly defined with concrete nouns and adjectives?
2. [ ] **Medium**: Is the artistic medium declared (e.g., photo, oil painting, 3D render, vector)?
3. [ ] **Lighting**: Is the light source, intensity, or mood specified?
4. [ ] **Composition**: Is the framing, lens type, or perspective clear?
5. [ ] **No Buzzwords**: Did you remove empty tags like `8k`, `masterpiece`, `trending`?
6. [ ] **Positive Phrasing**: Are instructions expressed as what *to* include rather than what *not* to include?
