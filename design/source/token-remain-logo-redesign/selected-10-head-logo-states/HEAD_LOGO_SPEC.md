# TokenRemain head-only app logo specification

## Visual layers

1. **Static product tile:** deep navy square background.
2. **Robot identity:** violet stepped-cube head with a cyan side status light.
3. **Mood layer:** one of the existing 11 cyan face expressions, resolved from
   the lowest available remaining quota.
4. **Meter layer:** a programmatic 10-segment provider bar. It must not recolor
   the robot shell.

## Provider resolution

Inputs are the current Claude and Codex remaining percentages when available.

1. Discard unavailable or stale provider values.
2. Resolve the mood-driving provider as the value with the lowest remaining
   percentage.
3. If only one provider remains, it drives both mood and meter.
4. If both values are equal, use Claude as the stable tie-breaker for compact
   presentation only.
5. Keep provider order stable in the dual layout: Claude above Codex.

The compact meter uses the selected provider's color. The spacious layout may
show both meters, but the face always uses the lower value.

## Colors

| Provider | Meter color | Empty track |
| --- | --- | --- |
| Claude | `#D97757` | `#252C43` |
| Codex | `#4B9CFB` | `#252C43` |

Do not replace the provider color with red at low quota. The face expression is
the urgency signal; the bar color remains a stable provider identity.

## Responsive layouts

| Rendered size | Presentation |
| --- | --- |
| Under 24 pt | Head only; omit meter because segments are no longer legible. |
| 24–47 pt | Head plus one compact five-segment meter for the lowest provider. |
| 48–71 pt | Head plus one ten-segment meter for the lowest provider. |
| 72 pt and above | Two ten-segment meters when both providers are available. |

## Platform behavior

- **iPhone system App Icon:** use `app-icon-static-calm.png`. Do not imply live
  quota in the primary system icon.
- **iPhone app UI, Widget, Live Activity, Dynamic Island:** render the current
  mood plus responsive meter from snapshot data.
- **Mac app UI:** render the current mood plus responsive meter.
- **Mac runtime Dock icon:** may use the current mood and meter while the app is
  running. The bundled icon remains the static calm master.
- **Menu bar glyph and very small complications:** use a simplified or
  monochrome head without the meter below 24 pt.

## Asset structure

- Root PNG files: provider-neutral head expressions.
- `metered-claude/`: 11 orange single-meter review variants.
- `metered-codex/`: 11 blue single-meter review variants.
- `metered-dual-examples/`: spacious dual-meter examples.
- `head-only-expression-board.png`: full expression review board.
- `head-logo-meter-system-board.png`: responsive/provider behavior board.
- `app-icon-static-calm.png`: static system App Icon candidate.

These files are design candidates. They do not replace the current app assets
or runtime renderer until the user approves the system.
