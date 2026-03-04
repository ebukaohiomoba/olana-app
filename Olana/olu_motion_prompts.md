# Olu — Lottie Motion Prompts
## Olanna App Mascot · All Four States

---

## HOW TO USE THESE PROMPTS

1. Export the approved Olu SVG from your design tool
2. Go to lottielab.com → New Animation → Import SVG
3. Copy and paste the relevant prompt below into the Motion Copilot or AI animation field
4. Export each state as a separate JSON file
5. Name files exactly as shown below

---

## STATE 1 — RESTING `olu_resting.json`
*When to use: App open, no activity. Default presence on home screen.*

> Animate this character as a seamless 4 second resting loop. The character is awake and content but calm and still — not actively floating.
>
> (1) BREATHING: The entire body scales very subtly from 100% to 103% and back over 2 seconds. The scale should grow slightly wider rather than taller, like a deep belly breath. Use ease-in-out curve throughout. Completely smooth, no snapping.
>
> (2) NO FLOAT: The character stays fully grounded. It does not move up or down — it only breathes.
>
> (3) BLINK: One slow natural blink at the 3 second mark. Both eyes squish vertically to near-zero height over 2 frames, hold for 1 frame, spring back over 2 frames. Left eye triggers 1 frame before the right for a natural feel. Eyes never fully disappear — just squish flat.
>
> (4) TAIL: One very small slow sway of 8 degrees over 2 seconds then returns to center. Just one gentle movement per loop — like a cat's tail resting, not wagging.
>
> (5) CHEEKS: Steady at 70% opacity throughout. No pulse. Warm and present.
>
> (6) HALO: Faint soft glow behind the character. Stays at a steady 25% opacity. No pulse. Just a quiet warm presence.
>
> The overall feeling: a small warm creature sitting quietly on your screen, alive but still, like a candle that isn't flickering. Safe, present, unhurried.

---

## STATE 2 — IDLE `olu_idle.json`
*When to use: User is actively scrolling, engaging with tasks, using the app.*

> Animate this character as a seamless 3 second idle loop. The character is awake, engaged, and gently alive.
>
> (1) BODY FLOAT: The entire character moves gently upward by 6 pixels over 1.5 seconds then returns to start. Use ease-in-out curve — soft and weightless, never snappy or bouncy.
>
> (2) BODY ROCK: While floating, the body rotates very slightly — no more than 2 degrees left and right, like a buoy on calm water. The rock should be slightly offset from the float timing so they never peak at the exact same moment.
>
> (3) BLINK: Once per loop at around the 2 second mark. Both eyes squish to near-zero height over 2 frames, hold 1 frame, spring back over 2 frames. Left eye triggers 1 frame before the right. Eyes never fully disappear.
>
> (4) TAIL WAG: The tail rotates on its own independent rhythm, swinging 15 degrees left and right on a 1 second cycle. Completely independent from the body float timing — they should never sync up perfectly.
>
> (5) CHEEK PULSE: The blush cheeks subtly increase in opacity from 60% to 85% and back over the full 3 second loop. Almost imperceptible but adds warmth.
>
> (6) HALO GLOW: A soft golden ellipse behind the character pulses in opacity from 20% to 45% and very slightly in scale from 100% to 108%, synced loosely with the upward float motion.
>
> The overall feeling: a small warm creature quietly alive and content, gently present with you.

---

## STATE 3 — SLEEP `olu_sleep.json`
*When to use: Night mode, after 9pm. Olu winds down with the user.*

> Animate this character as a seamless 3 second sleep loop. Same character as idle but sleepy and winding down.
>
> (1) FLOAT: Reduced to 3 pixels upward movement — barely moving. Very slow ease-in-out.
>
> (2) ROCK: Reduced to 1 degree rotation — almost completely still.
>
> (3) EYES: Permanently half-closed for the entire animation — squished to 40% of their normal height, never fully open. This is their resting state throughout.
>
> (4) BLINK REPLACED BY DROOP: At the 2 second mark, eyes gradually squish from 40% height to fully closed over 1 second, hold fully closed for 0.5 seconds, then slowly reopen to 40% height over 0.5 seconds. Heavy and slow — like fighting sleep.
>
> (5) TAIL: Slows to a 2.5 second cycle — barely moving. One very gentle sway per loop.
>
> (6) HALO: Dims significantly. Pulses between 10% and 25% opacity only. Color shifts slightly cooler toward amber-brown, away from bright gold.
>
> (7) OVERALL OPACITY: Entire character sits at 90% opacity — slightly dimmer than daytime, like soft lamplight.
>
> (8) ZZZ: A tiny "z" character floats upward from the top right of the character, fading in at 20% opacity, drifting up 8 pixels, then fading out. Repeats every 2 seconds. Color: soft lavender #C8B8E8 at very low opacity.
>
> The overall feeling: a tiny warm creature almost asleep, safe and content, no urgency whatsoever.

---

## STATE 4 — CELEBRATE `olu_celebrate.json`
*When to use: Task completed, friend checks in, milestone reached. Plays ONCE then returns to resting.*

> Animate this character as a 2 second celebration that plays once and does not loop. After it completes, return smoothly to the resting idle pose.
>
> (1) BOUNCE: Character moves upward 20 pixels quickly with fast ease-out over 0.3 seconds, then falls back down with ease-in over 0.4 seconds. On landing, the body squashes slightly wider (110% width, 92% height) for 2 frames, then springs back to normal over 3 frames.
>
> (2) EYES: During the upward bounce, both eyes curve into happy crescents — the tops of the eyes flatten into upward arcs. Hold for the duration of the bounce peak. Return to normal dots as the character lands.
>
> (3) ARMS: If the character has arm nubs, they briefly extend slightly outward during the bounce peak — a tiny cheer gesture — then return to sides.
>
> (4) HALO BURST: The halo rapidly expands from 100% to 160% scale and simultaneously fades from 70% to 0% opacity over 0.5 seconds. Like a warm pulse of light radiating outward.
>
> (5) SPARKLES: Three small 4-pointed star shapes pop outward from the character in three different directions (upper left, upper right, directly up). Each scales from 0% to 100% over 0.3 seconds then fades to 0% over 0.4 seconds. Color: warm gold #FFD166. They should feel like quiet sparks, not fireworks.
>
> (6) CHEEKS: Pulse to full 100% opacity brightness during the bounce peak, then settle back to normal 70% over 0.5 seconds.
>
> (7) RETURN: After all elements settle, character eases into the resting breathing animation seamlessly.
>
> The overall feeling: quiet warm pride. Not a party — just a small golden creature saying "you did it" with a little jump of joy.

---

## COLOUR REFERENCE
For any colour adjustments needed inside Lottielab:

| Element       | Day Hex   | Night Hex |
|---------------|-----------|-----------|
| Body main     | #F5A800   | #A07030   |
| Body highlight| #FFE08A   | #D4A860   |
| Body shadow   | #D97000   | #704A18   |
| Belly patch   | #FFE8A0   | #C09050   |
| Eyes          | #5C3010   | #3A1E06   |
| Blush cheeks  | #E87050   | #A05030   |
| Ear bumps     | #E09800   | #806020   |
| Halo glow     | #FFD166   | #C8A060   |
| Sparkles      | #FFD166   | n/a       |

---

## DEVELOPER TRIGGER LOGIC (React Native)

```javascript
// Pseudo-code for switching Olu states

const getOluState = () => {
  const hour = new Date().getHours();
  if (hour >= 21 || hour < 6) return 'sleep';     // 9pm–6am
  return 'resting';                                 // default
};

// On task complete:
playOnce('celebrate', then: 'resting');

// On user scrolling / active:
setState('idle');

// On user inactive > 10 seconds:
setState('resting');
```

---

*Olu is gold because of what Olanna means — precious, cherished, held close.
Not a sun. Just warm.*
