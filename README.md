# FastTravel Single-Player Mod for Assetto Corsa

A single-player teleportation mod that lets you click anywhere on an interactive map to instantly teleport around the track.

## Features

- **Interactive Map**: Press M to open a full-screen overhead map
- **Click to Teleport**: Left-click anywhere on the track to teleport
- **Multiple Zoom Levels**: Mouse wheel to zoom in/out (4 levels by default)
- **Free Camera Movement**: Move mouse to edges of screen to pan around
- **Auto-Align**: Car automatically aligns to track surface and direction
- **Collision Safety**: Automatically disables collisions during teleport
- **Track Map Overlay**: Shows the official track map at maximum zoom (if available)

## Requirements

- **Assetto Corsa** (original, not Competizione)
- **Custom Shaders Patch (CSP)** version 0.2.0 or newer
  - Recommended: CSP 0.2.8+ for full collision support

## Installation

1. **Copy the app folder** to your Assetto Corsa apps directory:
   ```
   Copy: fasttravel_app/
   To: [Assetto Corsa]/apps/lua/
   ```

   Full path example:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\fasttravel_app\
   ```

2. **Enable the app** in Content Manager or in-game:
   - Launch Assetto Corsa
   - Go to Single Player > Practice/Hot Lap
   - Select your car and track
   - Once loaded, the app will automatically activate

## Usage

### Basic Controls

- **M Key**: Toggle map on/off
- **Mouse Wheel**: Zoom in/out between levels
- **Mouse Movement**:
  - Move to screen edges to pan the map
  - Hover over locations to preview
- **Left Click**: Teleport to clicked location
- **ESC**: Close map

### Tips

- The mod shows "Press M key to FastTravel" when you're stationary
- At maximum zoom, the official track map image will overlay (if the track has one)
- The map shows:
  - **Yellow dot with arrow**: Your current position and direction
  - **Green circles**: Predefined teleport points (if configured)
  - **Green cursor**: Valid teleport location
  - **Red cursor**: Invalid location

### Settings

Access the settings by:
1. Press M to open the map
2. Look for the settings icon in the CSP extras menu
3. Adjust:
   - Map image position
   - Zoom levels
   - Movement speeds
   - Show/hide track map overlay

## Configuration

The app stores settings in `lua/fasttravel.lua`. You can edit these values:

```lua
disableCollisions = true,  -- Disable collisions during teleport
mapZoomValues = "{ 100, 1000, 4000, 15000 }",  -- Zoom level distances
mapMoveSpeeds = "{ 1, 5, 20, 0 }",  -- Pan speeds per zoom level
showMapImg = true,  -- Show track map image at max zoom
```

## Troubleshooting

### Map doesn't open when pressing M
- Make sure you're in single-player mode (Practice/Hot Lap/Race)
- Check that CSP is installed and enabled
- Verify the app is in the correct folder

### Can't teleport (red cursor)
- Make sure you're clicking on the track surface
- Try zooming in for more precision
- The raycast might not hit the track - move the map slightly

### Collisions not disabling
- You need CSP 0.2.8 (build 3424) or newer for collision disabling
- You can set `disableCollisions = false` if this causes issues

### Track map image not showing
- Not all tracks have a `map.png` file
- Check: `[AC folder]/content/tracks/[track name]/map.png`
- You can disable it with `showMapImg = false`

## How It Works

The mod uses CSP's physics API to directly teleport your car:
- `physics.setCarPosition(0, position, direction)` moves the player car
- Auto-aligns to track surface using raycasting
- Temporarily disables collisions for safety
- Uses grabbed camera to create overhead view
- Renders track geometry and roads in real-time

## Credits

- **Original Plugin**: Tsuka1427 (AssettoServer FastTravel plugin)
- **Contributions**: c1xtz, thisguyStan
- **Single-Player Adaptation**: Modified for offline use
- **License**: Based on AssettoServer (AGPL-3.0)

## Known Limitations

- Only works in single-player modes
- Requires tracks with proper road meshes for rendering
- Some tracks may not center correctly (adjust in settings)
- Cannot teleport to surfaces not detected by raycast

## Changelog

### Version 1.0.0
- Initial single-player release
- Removed all multiplayer/server dependencies
- Direct physics API teleportation
- Simplified UI with drawn cursors (no external images needed)
- Auto-centering for tracks
- Integrated debug settings window

## License

This mod is derived from the AssettoServer FastTravel plugin, which is licensed under AGPL-3.0.
You must preserve the legal notices and author attributions present in the code.
