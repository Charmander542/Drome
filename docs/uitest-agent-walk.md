# Drome XCUITest agent walk

## Goal

Walk the Listening Club UI via XCUITest, capture screenshots, then have the agent recommend design / UI fixes from those images.

## Pieces

| Piece | Path |
|-------|------|
| Decision tree (source of truth) | [`ios/DromeUITests/DecisionTree.json`](../ios/DromeUITests/DecisionTree.json) |
| Interactive editor canvas | Cursor canvas `drome-uitest-decision-tree` |
| Walker tests | [`ios/DromeUITests/DecisionTreeWalk.swift`](../ios/DromeUITests/DecisionTreeWalk.swift) |
| Launch hooks | `-UITestWalk`, `-UITestPodcastMini`, `-UITestShowOnboarding` |

## Run walks

```bash
cd ios
# Prefer an already-booted Simulator (id from `xcrun simctl list devices booted`).
DEST='platform=iOS Simulator,id=ADDE0271-BCB8-4DCF-ACE6-3DD63AA9685F'

# Tab circuit only
xcodebuild test -scheme Drome -destination "$DEST" \
  -only-testing:DromeUITests/DecisionTreeWalk/testSmokeTabCircuit \
  -resultBundlePath /tmp/drome-uitest-smoke.xcresult

# Full chrome: Settings tiles, Library filters, Search chips, music NP
# controls, Podcasts mini → Now Playing (run serially — parallel clones hang)
xcodebuild test -scheme Drome -destination "$DEST" \
  -only-testing:DromeUITests/DecisionTreeWalk/testFullChromeWalk \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -resultBundlePath /tmp/drome-uitest-full.xcresult

# Export screenshots from the result bundle:
# xcrun xcresulttool export attachments --path /tmp/drome-uitest-full.xcresult --output-path docs/uitest-shots
```

Screenshots appear as XCTest attachments (`uitest-walk-*`) and under the simulator temp `uitest-walk/` folder.

## Agent loop (recommended)

1. Charlie edits node **status** in the canvas (or JSON): `needs_ids` → `ready`.
2. Agent adds missing `accessibilityIdentifier`s for `needs_ids` critical nodes.
3. Agent runs `DecisionTreeWalk` on Simulator.
4. Agent reads screenshot attachments / PNGs with the image tool.
5. Agent files concrete UI fixes (spacing, contrast, hierarchy, missing empty states).
6. Re-run the walk; mark nodes `ready` when stable.

## Priority order

1. **critical** smoke: tabs · Home · Search · Library · Now Playing · Settings  
2. **high**: Daily Mix · Wishlist · Podcasts · EQ · Queue  
3. **medium / low**: edge sheets, diagnostics  

## Launch arguments

| Arg | Effect |
|-----|--------|
| `-UITestWalk` | Marks session as UI-test walk (reserved for future gates) |
| `-UITestPodcastMini` | Forces signed-in shell + podcast mini chrome without a real server |
| `-UITestShowOnboarding` | Forces feature tour so Continue can be exercised |

For library-backed walks (play real music), use a saved Simulator account instead of `-UITestPodcastMini`, or add a future `-UITestDemoServer` hook pointed at `demo.navidrome.org`.

## Editing the tree

- Prefer the **canvas** (`drome-uitest-decision-tree`) for review / status overrides.
- Persist structural changes (new screens/actions) in **DecisionTree.json**, then mirror into the canvas `NODES` array.

## Latest walk shots

Copied after a green `testFullChromeWalk` (Settings tiles, Library filters, music + podcast NP):

`docs/uitest-shots/` — includes `music-now-playing`, `podcast-now-playing`, `library-*`, `settings-*`, etc.

`-UITestWalk` / `-UITestPodcastMini` seed chrome-only music + podcast state. If the Simulator already has a signed-in Navidrome account, Home/Library show real library data under that chrome.
