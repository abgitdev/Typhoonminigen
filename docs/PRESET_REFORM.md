# Preset reform (audit 2026-06-10 — owner-approved, implemented in v0.42; candlelight dropped per owner decision)

Result of a 9-agent audit: commercial tools (Firefly, Leonardo, KREA, Freepik, Ideogram, MJ, Canva),
open-source (Fooocus, A1111, InvokeAI, Draw Things), professional photography vocabulary,
FLUX.2/Klein-specific modifier efficacy (BFL guide, fal.ai, community A/B), full code inventory.
All numbers verified against `PromptPreset.swift` (108 built-in chips today). Verifier corrections applied.

## Headline

**108 → 72 built-in chips** across 11 axes (was 10) **+ new LOOKS group: 8 one-tap bundles**.
(2026-06 studio pack addendum: 72 → 77 chips — 3 lighting + 2 environment — and 8 → 11 bundles; see LOOKS list below.)
No category deleted; SUBJECT group cut hardest (39 → 17) — no commercial tool exposes pose/expression
at all, but the owner's short-prompt workflow needs a minimal core. Everything dropped returns via
custom chips in seconds (mechanic exists).

## Per category (final, corrections applied)

### Pose 20 → 7 (single)
KEEP: contrapposto, hand on hip, arms crossed, leaning, walking, glance over shoulder
(rename of overshoulder; phrase "looking back over one shoulder at the camera").
ADD: `pose.seated` → "seated, poised and relaxed" (fashion needs one non-standing pose).
DROP (14): standing (no-op default), hands-on-hips + hands-in-pockets (variants), hand-in-hair,
touching-face, sit-chair, sit-floor, kneeling, crouching, lying + reclining (dupes of each other),
running, jumping (unstable at 4 steps), from-behind (moved to Angle as rear view).

### Expression 9 → 5 (single)
KEEP: neutral (anti-AI-smile reset), soft smile, laughing, serious, sultry gaze.
DROP: joyful (dupe of laughing — both phrases say "joyful"), confident (≈serious at 4 steps),
thoughtful (weak visual delta), surprised (niche).

### Object & placement 10 → 5 (single)
KEEP: flat lay, floating, held in hand, on a pedestal, grouped.
DROP: resting-on-surface (no-op + stutters with env surfaces), standing-upright (default),
lying-flat (niche), hanging (≈floating), leaning (dupe of pose.leaning).

### Framing 7 → 5 (single)
KEEP: extreme close-up; close-up (REPHRASE generic: "close-up shot, the subject filling most of
the frame" — must work for products, not only people); half body; full body (REPHRASE generic:
"full shot, the entire subject in frame head to toe"); wide / scene.
DROP: portrait (merged into close-up), fills-frame (dupe of extreme close-up).
(centered / negative space moved to new Layout axis — they are composition style, not scale,
and must combine with the scale ladder.)

### NEW: Layout 2 (multi) — group COMPOSITION
`frame.centered` → "perfectly centered, symmetrical composition" (STRONG on Klein).
`frame.negspace` → "minimalist composition, vast empty negative space around the subject" (STRONG).
("rule of thirds" by name confirmed dead on FLUX — not added.)

### Angle 8 → 7 (single)
KEEP: eye level (reset), low angle (vehicle staple), high angle, overhead, aerial / drone.
ADD: `angle.threequarter` → "three-quarter view, showing the front and side of the subject"
(product/automotive standard); `angle.rear` → "seen from behind, rear three-quarter view"
(dress-back / car-rear — replaces pose.frombehind properly).
DROP: Dutch tilt (~50% ignored by Klein), over-shoulder (collides with pose chip), POV (niche).

### Lens & focus 10 → 6 (single)
DOF folded into focal phrases; deep focus stays as the product alternative.
KEEP+REPHRASE: 85mm → "shot on an 85mm f/1.4 lens, razor-thin depth of field, creamy bokeh";
50mm as is; 24mm → "shot on a 24mm wide-angle lens, expansive view, exaggerated perspective";
macro as is; deep focus → "deep focus at f/8, everything sharp from front to back" (BFL skills repo);
medium format as is (Hasselblad = official BFL example).
DROP: 35mm (indistinct from 50/24 at 4 steps), 135mm (reads as blur), shallow DOF (folded into 85mm),
fisheye (niche).

### Environment 17 → 10 (single)
KEEP: studio (REPHRASE: "in a photography studio against a clean white seamless backdrop" — white
is the e-commerce canon), forest (KEPT — owner's literal scenario, verifier overruled the drop),
mountains, desert, urban street, neon city night (REPHRASE: "on a rain-slicked city street at
night, glowing signs" — removes "neon" stutter with the lighting chip), luxury interior,
industrial, marble surface, wooden table.
DROP: white cyclorama (dupe of studio), outdoors/nature (vague), beach, rooftop, cozy interior,
concrete, water surface (niche for owner's use; custom chips cover).

### Lighting 12 → 12 (multi) — biggest budget; BFL: highest-impact axis
KEEP: golden hour, blue hour, soft studio (softbox), rim light, hard sun, overcast, neon,
low-key, high-key.
REPHRASE (rule: term + what the light DOES): window light → "soft window light from one side,
gentle falloff into shadow"; Rembrandt → "dramatic 45-degree side lighting, deep shadows, a small
triangle of light on the shadowed cheek".
ADD: `light.flash` → "direct on-camera flash, harsh bright light, 2000s snapshot feel"
(BFL-official look, fashion-current).
DROP: candlelight — ⚠️ OWNER DECISION: it IS high-efficacy (only such drop in the whole reform);
cut purely for frequency. Keep if he ever shoots candle scenes.

### Style 8 → 5 (multi) — minimal, LoRA-friendly
KEEP: editorial, documentary, product / ad.
REPHRASE: cinematic → "cinematic film still, dramatic movie lighting" (corrected: no "shallow
focus" leak into the Lens axis, no "color grading" leak into Color).
ADD: `style.automotive` → "professional automotive photography, glossy paint reflections on
bodywork" (low angle deliberately NOT baked in — separate chip).
DROP: photoreal (FLUX default, ≈no-op), analog film (dupe of Portra grain).
MOVE OUT: Kodak Portra, black & white → Color & film.

### Color grade → rename "Color & film" (title only! rawValue "color" persists) 7 → 8 (multi)
KEEP: warm, cool, teal & orange, vibrant, muted, pastel.
MOVE IN: `color.bw` → "high-contrast black and white, deep blacks, bright highlights";
`color.portra` → "shot on Kodak Portra 400 film, soft warm skin tones, fine grain".
DROP: high contrast (triple overlap with b&w/low-key).

## LOOKS — one-tap bundles (new group, row above categories; 8 at v0.42, 11 after studio pack)

Bundle = static list of chip ids. Tap = CLEAR current selection, then SET (idempotent
`selectPreset`, not `togglePreset` — toggle would deselect already-active chips). Re-tap = clear.
Active = `bundle.chipIDs ⊆ selectedPresetIDs`. Skip (or unhide) hidden ids on apply.
Rationale: Leonardo 19 / Canva 26 / Freepik bundles are the dominant commercial pattern;
clear-then-set avoids multi-select garbage accumulation between bundles.

1. Clean Product — product, studio, softbox, deep focus, three-quarter (+ high-key optional)
2. Hero Product — product, pedestal, low-key, rim light, medium format
3. Editorial Fashion — editorial, Rembrandt, half body, 85mm, muted
4. Cinematic Portrait — cinematic, window light, close-up, 85mm, teal & orange
5. Film Portrait — Portra, golden hour, close-up, 85mm
6. Street Candid — documentary, urban street, overcast, 50mm, full body
7. Automotive Golden Hour — automotive, mountains, golden hour, low angle, 24mm
8. Neon Night — cinematic, neon city night, neon light, 50mm
9. Studio Portrait — studio, 3-point studio, half body, 85mm *(studio pack, 2026-06)*
10. Beauty Studio — studio, clamshell beauty, close-up, medium format *(studio pack, 2026-06)*
11. Color Pop — color seamless, gelled duo, editorial, half body *(studio pack, 2026-06)*

Each bundle ≈ 32-44 words → with a 10-20-word prompt lands in (or near) Klein's 40-70 word optimum.

## UX / mechanics

- Append order: UNCHANGED (verified identical to BFL extended formula; display order is decoupled).
- Display order: LOOKS → SCENE (Lighting expanded by default) → COMPOSITION → LOOK → SUBJECT
  (collapsed, bottom). Lighting first = highest impact.
- Conflict pairs (multi-select; selecting one removes the other): lowkey↔highkey, hardsun↔overcast,
  hardsun↔softbox, golden↔blue, golden↔overcast, flash↔softbox, flash↔overcast, rembrandt↔highkey,
  warm↔cool, vibrant↔muted, bw↔{vibrant, pastel, tealorange, warm, cool, portra};
  studio pack adds: clamshell↔hardsun, clamshell↔flash, threepoint↔hardsun, gelled↔golden.
- Word counter: extend existing promptIsLong (threshold 70) into a live "prompt + chips ≈ N words"
  indicator (green 40-70, amber >70).
- LoRA hint on Style/Color categories when any LoRA active (no style/subject metadata exists —
  soften wording: "A LoRA is active — style chips may fight it").
- Migration: free — init already filters stale ids; hiddenIDs garbage harmless (verified).
- "Clear" button already exists (no-op item).
- Custom-chip placeholder teaches phrasing: "term + visible effect, 4-10 words".

## Implementation estimate

M (~one session chunk): PromptPreset.swift catalog rewrite + bundles struct; PresetsSection.swift
LOOKS row + counter + LoRA hint; GenerateViewModel idempotent `selectPreset` (~10 lines) +
conflict map. Files: Models/PromptPreset.swift, Views/Generate/PresetsSection.swift,
ViewModels/GenerateViewModel.swift.
