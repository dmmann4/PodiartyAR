# Foot Scan 3D — TrueDepth capture pipeline

Swift source for scanning a foot with the front TrueDepth camera, building an
interactive 3D mesh, and exporting it for 3D printing.

## Files

| File | Responsibility |
|---|---|
| `TrueDepthCaptureManager.swift` | AVFoundation session on `.builtInTrueDepthCamera`, synchronized depth + color frames |
| `PointCloudProcessing.swift` | Depth → 3D point unprojection, subject segmentation, fast stationary-frame averaging (`FrontSurfaceCapture`), plus a walk-around ICP aligner/accumulator kept for a possible future full-360° mode |
| `MeshReconstruction.swift` | `FrontSurfaceMesher` (default): open, front-only mesh straight from one depth grid. `MeshReconstructor` (legacy): voxel occupancy → closed/watertight mesh, for the walk-around path |
| `ModelExporter.swift` | OBJ / binary STL / PLY / USDZ export, SceneKit geometry conversion |
| `FootScanView.swift` | SwiftUI + SceneKit UI: scan, reconstruct, orbit/zoom, export, share sheet |

## Capture mode: fast single-viewpoint (default)

The default flow now mirrors a "hold the phone still for a moment" capture
rather than a walk-around scan:

- The user points the front camera at their hand and holds it roughly still.
- `FootScanViewModel` accumulates depth frames into `FrontSurfaceCapture` for
  a fixed ~1.2 second window — a plain per-pixel running average, since the
  camera isn't moving there's no alignment to solve for between frames.
- `FrontSurfaceCapture.finish()` averages the window, segments out the
  nearest continuous surface (the hand, not the wall behind it), and hands
  the resulting depth grid to `FrontSurfaceMesher`, which triangulates it
  directly — producing an **open, single-sided mesh of just the surface
  facing the camera**, not a closed volume.
- The whole thing — camera-up to reviewable model — takes a couple of
  seconds, and the result intentionally has no back/sides, because no data
  from those angles was ever captured.

This is a smaller/lighter scan than the old approach on purpose: it trades
"complete 360° geometry" for "fast, and you can immediately see the result",
matching how a quick capture-and-preview experience is expected to feel.

### Legacy capture mode: walk-around / ICP merge

`PointCloudAccumulator` + `ICPAligner` (in `PointCloudProcessing.swift`) and
`MeshReconstructor` (in `MeshReconstruction.swift`) implement a different,
slower flow: sweep the camera around the subject, ICP-align each new frame
onto the accumulated cloud, and voxelize the merged result into a closed,
watertight mesh once ~260° of rotation has been covered. This code is kept
in the project (currently unused by `FootScanView`) in case a "detailed,
full-model 360° scan" mode is wanted alongside the fast default — building a
mesh that's genuinely closed on every side needs multi-angle data, which a
single-viewpoint capture fundamentally can't provide.

## Setup

1. Add these files to an Xcode project (iOS 15+ recommended for the `SceneView`/
   `async`/`await` usage; adjust if targeting older OS versions).
2. Add to `Info.plist`:
   ```xml
   <key>NSCameraUsageDescription</key>
   <string>Used to scan your foot for a custom orthotic model.</string>
   ```
3. Run on a **physical device** with a TrueDepth camera (iPhone X or later, or
   iPad Pro with Face ID). The simulator has no camera hardware.
4. Present `FootScanView()` from wherever makes sense in your app.

## Important hardware caveat: TrueDepth vs. LiDAR

You asked specifically for the front TrueDepth camera, so that's what this
code uses. Worth knowing before you invest in tuning it further:

- **TrueDepth** was built for Face ID / face-tracking distances — roughly
  15cm to 1m, with best accuracy under ~50cm and a fairly narrow field of
  view. It'll capture a foot, but the working volume is small, so you'll be
  scanning at close range and doing more stitching (more ICP frames) to cover
  the whole foot.
- **The rear LiDAR scanner** (iPhone 12 Pro and later Pro models, most iPad
  Pros) has a longer effective range, a wider field of view, and — critically
  — ARKit exposes it directly through `ARWorldTrackingConfiguration` with
  `sceneReconstruction = .mesh` and `frameSemantics = .sceneDepth`. That gives
  you camera pose tracking *and* depth for free, which removes the entire
  custom ICP alignment step in `PointCloudProcessing.swift`. Most commercial
  foot-scanning/orthotic apps use this path, not TrueDepth.

If you have access to a LiDAR-equipped device, it's worth prototyping that
path in parallel — it will very likely get you to a usable scan faster and
with better accuracy than the front-camera pipeline here.

## Accuracy notes for orthotics specifically

- The mesh reconstruction in `MeshReconstruction.swift` is a simple voxel
  occupancy mesher, not a full Poisson/marching-cubes reconstruction. It's
  dependency-free and easy to audit, but it will produce a coarser surface
  than dedicated reconstruction software. Treat it as the on-device
  preview/interaction layer.
- For anything actually going to a printer for a wearable orthotic, run the
  exported raw point cloud (`exportRawPointCloudPLY`) through a proper offline
  reconstruction tool (e.g. Open3D's Poisson reconstruction, MeshLab, or
  Netfabb) before printing, and inspect/repair the mesh (fill holes, check
  it's manifold/watertight) in that tooling.
- Orthotic fabrication generally has tight tolerance requirements. Multiple
  scan passes, a stable capture rig (rather than handheld), and consistent
  lighting will matter a lot for repeatability. This pipeline is a good
  starting point for a capture/preview app, not a substitute for validation
  against a certified orthotist's own measurement process before anything is
  fabricated and fitted to a patient.

## Export formats

- **STL (binary)** — the near-universal input for slicers and orthotic
  CAD/CAM software.
- **OBJ** — human-readable, widely supported for inspection/editing.
- **PLY** — raw point cloud, meant for feeding a proper offline reconstruction
  pipeline rather than for printing directly.
- **USDZ** — for AR Quick Look previews / easy sharing on Apple platforms.
