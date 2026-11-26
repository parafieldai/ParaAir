# ParaAir app design

Last updated: 2026-11-26

The Mac app's interface language is **Air**. Its values live in one file, `macOS/App/AirStyle.swift`; this page says what
they are for. Air replaced the earlier Glide tokens (warm paper, New York serif, a chamfered sage button) in alpha.10.

Air is the website's language in the app: a cool paper, ink type set tight, sections set as type on the paper between
hairlines, flat capsule controls, slow eased motion, and ParaAir's own signature, the planes. ParaAir keeps its own name,
mark, copy and its one colour, the mark's sage.

## Colour

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `paper` | `#F7F8FA` | `#0C0D10` | Window, sheet and panel surface, with fine grain |
| `ink` | `#0E0F12` | `#F6F7F9` | Text, the prominent button's fill, the lead plane |
| `quiet` | `#646974` | `#969CA8` | Supporting text, values, notes, the state under a name (4.8:1 or more everywhere it sits) |
| `muted` | `#EEF0F3` | `#1A1C20` | Tracks, hover and pressed fills |
| `rule` | `#E6E8EC` | `#24272C` | Hairlines above rows; the edge of a sheet |
| `ruleStrong` | `#C9CDD4` | `#3A3E46` | The outline of secondary buttons |
| `sheet` | `#FDFDFE` | `#15161A` | Panels that hold a choice: a plan, the full terms, the drive icon's well |
| `accent` | `#3F6B5A` | `#588974` | Switches that are on; the only colour besides ink |
| `trail` | `#5E9C83` | `#9AC7B4` | The sage line under a name and the lead plane's trail |
| `planeGrey`, `planeFold` | `#A4A9B2`, `#D3D7DD` | `#5E646F`, `#3A3F47` | The flock: the mark in two greys, its fold a step nearer the paper |
| `good`, `attention`, `problem` | `#3F6B5A`, `#8A5A12`, `#A63A2A` | `#9AC7B4`, `#E2B46B`, `#EE8F7E` | Status symbols and messages |

These are the website's values (`site/styles.css`: `--sage-line`, `--rule-strong`, `--plane-grey`, `--plane-fold`).
No panel or button casts a shadow: there are no cards, and a sheet is a flat fill a shade lighter than the paper with a
hairline edge. Only a switch's white knob keeps a hairline shadow, so it reads on the light track.

## Type

San Francisco at two weights. Display lines (`airDisplay`) are medium, tracked in by 3% of their size: 30 pt for the home
window's name, 24 pt for sheet titles, 19 pt in the menu bar panel, 34 pt for plan and storage figures. The name stands
alone in ink with the sage line beneath it; the state sits on its own line below, 15 pt medium in the quiet tone beside
its tone's symbol (13 pt in the panel), so there is no two-tone headline. Section names are 15 pt medium above their
rows; the type uses regular and medium only. Paths and versions use the monospaced face; nothing else does.

## Shape and space

- No cards. A section is its name, then rows on the paper with a hairline above, between and below them, as the
  website lists the repository's folders. Rows have 12 pt above and below their content and no side inset, so they line
  up with the section's name. In the menu bar panel, the drive list's closing line is also the panel's rule.
- Sheets (plan choices, the terms box, the icon well): 22 pt continuous corners (`Radius.sheet`), or 12 pt for inset
  boxes. Fields: 9 pt.
- Buttons, segmented controls, pop-up menus and switches are capsules (circular ends: the default continuous capsule
  draws stray stubs at its ends in macOS 27).
- A 4-point scale. The window margin is 28 pt; sections are 26 pt apart.

## Controls

- `airProminent`: the one ink action per view. A flat ink capsule with the paper as its label, as the website's button.
  Hover takes 14% opacity off, press 26%; it never moves. A destructive role fills it with the problem tone.
- `airOutline`: every other button (the default inside `airSurface()`). A capsule outlined in `ruleStrong` on the
  paper; hover fills it with `muted`, press deepens the fill.
- `airText`: small text actions beside a heading (Refresh), the panel's More menu and Quit.
- `AirFlow`: a row of buttons that wraps onto a second line rather than widening its window.
- `airSwitch`: toggles are rows, label leading and a capsule switch trailing; the knob slides, the track turns sage.
  A switch that is off, a field and a checkbox are edged by `controlEdge` (3:1 or more). The plan sheet's consent stays a
  native checkbox, so its sentence ticks it and the links in it open.
- `AirSegmented`: a track with a white thumb, edged in `controlEdge` (3:1 or more), that slides to the chosen option.
  `AirMenuPicker`: a pop-up choice as an outlined capsule. `airField()`: a white well with a hairline edge and the
  system focus ring.
- `AirMeter`: a 6 pt capsule bar on its own `track` tone that eases to its value.

Each custom control keeps standard semantics for VoiceOver and the keyboard through `accessibilityRepresentation` (a
native toggle, segmented picker or pop-up button), and every button stays focusable.

## The planes

The website's signature, drawn by `airFlight(_:)` over a header from the shared mark geometry (`AirPlane`). The words a
plane flew under mark themselves with `airUnderlined()`, and the planes fly beside them, never over them; About marks its
sky band with `airSky()`. A plane is centred on its own bounds and reaches 0.59 of its size ahead and behind and 0.37
to either side (`AirPlane.reach`); every clearance uses those figures. Trails are single tapered shapes, full at the
plane and nothing at the tail: the lead's in sage, a near flock plane's a faint grey line of about 45 pt behind its tail.

- **Home window** (`.window`): the drive's name has a sage line beneath it, fading in from the left over about one and
  a half letters (a third of the line at most), so a short name reads as underlined from its first letter. A lead plane in ink
  and the mark's sage rests in the open paper to the right of the name, from the margin above the header to just below
  the name, so no plane meets the state line. Its sage trail curves back toward the end of the line, and a small grey
  flock flies around it, heading the same way, near planes larger with a faint grey trail. The sky depends on the name
  alone, so a change of state never moves a plane, and each plane keeps its place as a share of the open paper, so
  resizing slides the flock rather than shuffling it. The flock needs 200 pt of open paper and the lead 120 pt; with
  less, there is only the line. The flock's places are seeded by the drive's name, so each drive keeps its own sky.
- **Menu bar panel** (`.panel`): one small plane just off the end of the line, its trail leaving the line's end. No
  flock.
- With no drive icon, the bare mark stands in beside the name in the flock's greys, so the lead plane is the one mark in
  ink and sage in each header.
- **About** (`.about`): a larger lead plane and its flock in the sky band above "ParaAir", clear of the window's buttons.

## Motion

Two curves. Things that arrive or move use `reveal` (cubic-bezier 0.22, 1, 0.36, 1; 0.7 s) or its 0.4 s form
`settle`; hover and colour changes use `hover` (0.4, 0, 0.2, 1; 0.2 s), press `quick` (0.15 s). The lead plane's
entrance is the one exception: it keeps the website's hero entrance, an ease-out cubic over 1.5 s.

- When the home window opens, the lead plane flies in once: it runs straight under the name at the tip of the sage line,
  drawing it, at half its size so it passes between the name's descenders and the state line, and only once past the
  last letter climbs into its place, growing to full size as it nears.
  This is the website's hero entrance. Nothing else in the sky moves, and nothing moves while the window is open.
- A changed state's words come out of a 4-point blur. Rows, notices and sections that come and go rise 6 pt from 96%
  scale as they fade in; the rest of the page settles around them.
- The segmented thumb slides; the switch knob slides; disclosure chevrons turn and their content rises in.
- Work under way (connecting, verifying, loading buckets) sweeps a slow ink band across its quiet text.

Content never waits on an animation: views are fully drawn at rest, and motion only moves what is already there; the
line under the name and the lead plane wait only for the entrance, which lands by the clock after 1.55 s whether or not
its frames were drawn. Under Reduce Motion nothing
slides, scales, blurs or flies: state changes are immediate, the planes and the line are where they rest from the start
(turning it on mid-flight lands them at once), the shimmer stops, and only hover and press keep their colour fades.
The snapshot harness sets `airAmbientMotion` to false so captures show the resting frame.

## Verifying

`scripts/render-ui-snapshots.sh` renders every screen offscreen in light and dark (home window, menu bar panel, Storage
Settings, the plan sheet, account deletion, Members, Drive Appearance, About, Changes to Review) and checks the
presentation logic and that ink and outlined buttons share each control size's height.
