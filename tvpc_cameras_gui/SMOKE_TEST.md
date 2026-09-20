# tvpc-cameras-gui smoke test

Run from the repo root or the tvpc_cameras_gui package directory.

## 1) Launch
- `python3 -m tvpc_cameras_gui` or `tvpc-cameras-gui`
- Verify:
  - Dark theme is applied
  - Toolbar actions are spaced and sized for 10-foot use
  - Status bar shows the idle/loaded message

## 2) Empty state
- With no cameras configured:
  - Empty state shows “No cameras yet”
  - “Scan network for cameras” and “Add camera manually” buttons are visible

## 3) Scan flow
- Open **Scan network**
- Start a scan and verify:
  - Progress/log output updates
  - Discovered items appear in the list
  - New items scroll into view
  - Empty-result state gives actionable guidance

## 4) Add/edit
- Add a camera manually
- Edit an existing camera
- Verify:
  - Fields preserve/load correctly
  - Save returns to main window
  - List shows the new/updated camera

## 5) Preview selection and navigation
- Select cameras in the left list
- Use arrow keys to move selection
- Verify:
  - Selected preview has a visible focus/selection indicator
  - Details panel updates for the selected camera

## 6) Playback actions
- Open selected in PiP
- Fullscreen
- Record/Snapshot
- Close PiP
- Verify:
  - mpv windows open/close correctly
  - Recording state appears on the preview

## 7) Motion badge scaling
- Trigger motion on a configured camera
- Verify:
  - Motion badge appears in the preview
  - Badge scales with the TV font size setting

## 8) UI scaling
- Open Settings > Interface
- Change TV font size
- Apply and verify:
  - Toolbar, list, buttons, and preview captions scale together
  - Spacing remains consistent
  - No clipping or overlapping
