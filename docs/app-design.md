# ParaAir app design

Last updated: 2026-11-26

The Mac app's interface language is **Air**. Its values live in one file, `macOS/App/AirStyle.swift`; this page says what
they are for. Air replaced the earlier Glide tokens (warm paper, New York serif, a chamfered sage button) in alpha.10.

Air follows the design language of current file-system products on the web: a cool paper, ink type set tight, glass
cards, capsule controls and slow, eased motion. ParaAir keeps its own name, mark, copy and its one colour, the mark's sage.

## Colour

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `paper` | `#F7F8FA` | `#0C0D10` | Window, sheet and panel surface, with fine grain |
| `ink` | `#0E0F12` | `#F6F7F9` | Text, the prominent button's fill |
| `quiet` | `#646974` | `#969CA8` | Supporting text, values, notes (4.8:1 or more everywhere it sits) |
| `muted` | `#EEF0F3` | `#1A1C20` | Tracks, hover and pressed fills |
| `rule` | `#E6E8EC` | `#24272C` | Hairlines between rows |
| `accent` | `#3F6B5A` | `#588974` | Switches that are on; the only colour besides ink |
| `good`, `attention`, `problem` | `#3F6B5A`, `#8A5A12`, `#A63A2A` | `#9AC7B4`, `#E2B46B`, `#EE8F7E` | Status symbols and messages |

Cards are a near-white (light) or graphite (dark) sheet that lightens toward its top, edged by a hairline of its own tone
and lit along the top lip. Their shadow comes from a smaller copy tucked under the card, so it pools below the bottom edge
and never rings the sides.

## Type

San Francisco at two weights. Display lines (`airDisplay`) are medium, tracked in by 3% of their size: 30 pt for the home
window's headline, 24 pt for sheet titles, 19 pt in the menu bar panel, 34 pt for plan and storage figures. A headline is
two-tone: the drive's name in ink over its state in the quiet tone, at the same size; a state too long for one line steps
down in size rather than stacking. Section names are 15 pt medium above their card; the type uses regular and medium only. Paths and versions use the
monospaced face; nothing else does.

## Shape and space

- Cards: 22 pt continuous corners. Inset boxes (the terms box, the icon well): 12 pt. Fields: 9 pt.
- Buttons, segmented controls, pop-up menus and switches are capsules (circular ends: the default continuous capsule
  draws stray stubs at its ends in macOS 27).
- A 4-point scale. The window margin is 28 pt; sections are 26 pt apart; rows are 11 pt above and below their content,
  separated by hairlines.

## Controls

- `airProminent`: the one ink action per view. Ink capsule, the paper as its label, a tight shadow beneath. Hover takes
  14% opacity off, press 26%; it never moves. A destructive role fills it with the problem tone.
- `airGlass`: every other button (the default inside `airSurface()`). Translucent white (light) or 6% white (dark)
  with a hairline edge; hover brightens fill and edge.
- `airText`: small text actions beside a heading (Refresh), the panel's More menu and Quit.
- `AirFlow`: a row of buttons that wraps onto a second line rather than widening its window.
- `airSwitch`: toggles are rows, label leading and a capsule switch trailing; the knob slides, the track turns sage.
  A switch that is off, a field and a checkbox are edged by `controlEdge` (3:1 or more). The plan sheet's consent stays a
  native checkbox, so its sentence ticks it and the links in it open.
- `AirSegmented`: a track with a white thumb that slides to the chosen option. `AirMenuPicker`: a pop-up choice as a
  glass capsule. `airField()`: a white well with a hairline edge and the system focus ring.
- `AirMeter`: a 6 pt capsule bar on its own `track` tone that eases to its value.

Each custom control keeps standard semantics for VoiceOver and the keyboard through `accessibilityRepresentation` (a
native toggle, segmented picker or pop-up button), and every button stays focusable.

## Motion

Two curves. Things that arrive or move use `reveal` (cubic-bezier 0.22, 1, 0.36, 1; 0.7 s) or its 0.4 s form
`settle`; hover and colour changes use `hover` (0.4, 0, 0.2, 1; 0.2 s), press `quick` (0.15 s).

- A changed state's words come out of a 4-point blur. Rows, notices and sections that come and go rise 6 pt from 96%
  scale as they fade in; the rest of the page settles around them.
- The segmented thumb slides; the switch knob slides; disclosure chevrons turn and their content rises in.
- Work under way (connecting, verifying, loading buckets) sweeps a slow ink band across its quiet text.
- The airflow field drifts sideways in a 60-second seamless loop.

Content never waits on an animation: views are fully drawn at rest, and motion only moves what is already there.
Under Reduce Motion nothing slides, scales, blurs or drifts: state changes are immediate, the drift and the shimmer
stop, and only hover and press keep their colour fades. The snapshot harness sets `airAmbientMotion` to false so
captures show the resting frame.

## The airflow field

Behind the home window's header and the About window: two twisted ribbons of fine dots,
one slate and one in the mark's sage, drawn once per appearance (`Airflow`). Text that must stay legible marks itself
with `airClearsField()`, and the ribbons start a little to its right; they fade out above and below the header band,
and leave entirely when less than 180 pt is left. The menu bar panel is too narrow for them. The website draws the same
ribbons, with the ParaAir plane flying along one of them.

## Verifying

`scripts/render-ui-snapshots.sh` renders every screen offscreen in light and dark (home window, menu bar panel, Storage
Settings, the plan sheet, account deletion, Members, Drive Appearance, About, Changes to Review) and checks the
presentation logic and that ink and glass buttons share each control size's height.
