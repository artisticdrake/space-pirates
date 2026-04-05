# Background Assets Brief — Rogue Signal

## Overview
This document outlines all background images needed for the game's cutscenes.
All backgrounds are static 2D images displayed behind character portrait boxes and dialogue text.
Characters are NOT placed inside backgrounds — they appear as separate portrait overlays.

---

## Art Style
All backgrounds must follow this prompt style string:

`2D anime visual novel background, cinematic widescreen, painterly anime art style, stylized not realistic, soft brush strokes, no characters, no text, no UI elements, dark sci-fi space setting, deep blues and blacks, clean painterly style, in the style of a Japanese visual novel, flat color areas, anime game background art`

---

## ACT 1 — Backgrounds

### BG_1 — Spaceship in Stars
- **Used in:** Cut Scene 1A and Cut Scene 1B
- **Description:** Single spaceship floating in deep space surrounded by stars
- **Notes:** One image reused across both scenes. We have a ship reference image — use it so the ship design matches the game's actual ship.

---

## ACT 2 — Backgrounds

### BG_2A — Rebel Base Exterior
- **Used in:** Cut Scene 2A
- **Description:** Large rebel space base built into an asteroid, industrial and worn, warm amber lights dotting the structure, ships docked around it, deep space background

### BG_2B — Cargo Ship Explosion
- **Used in:** Cut Scene 2B
- **Description:** Massive cargo spaceship exploding in deep space, chain reaction blast, debris flying outward, dramatic orange fire against black void

---

## ACT 3 — Backgrounds

### BG_3A — Two Ships Flying
- **Used in:** Cut Scene 3A
- **Description:** Two spaceships flying close together side by side in deep space, warm glow from distant explosion behind them
- **Notes:** Use ship reference image for both ships so they match the game's actual ship designs

### BG_3B — One Ship Destroyed
- **Used in:** Cut Scene 3B
- **Description:** Two spaceships in deep space — one intact and still, one broken and drifting with visible damage, cold dark silence
- **Notes:** Use ship reference image. This is an emotionally heavy scene — the mood should feel cold and empty

---

## Summary

| Asset ID | Scene | Description |
|---|---|---|
| BG_1 | CS 1A + CS 1B | Single spaceship in stars |
| BG_2A | CS 2A | Rebel base exterior |
| BG_2B | CS 2B | Cargo ship explosion |
| BG_3A | CS 3A | Two ships flying together |
| BG_3B | CS 3B | One ship destroyed, one intact |

**Total: 5 background images**

---

## Important Notes for Generation
- Use Nano Banana (Gemini image model) for generation
- Always include the full style string at the start of every prompt
- For any background featuring ships, upload the ship reference image alongside the prompt
- Generate each background in a separate session
- BG_3A and BG_3B can be done in the same session — generate 3A first, then upload it as reference for 3B and prompt the damage change so the composition stays consistent
