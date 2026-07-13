# LiDAR foot scanning → custom orthotics (iOS, pure Swift)

A code skeleton for: ARKit/LiDAR capture → mesh fusion & foot isolation → ML landmark
detection → interactive RealityKit viewer → USDZ/OBJ/STL export for manufacturing.

## Why not just use the raw LiDAR mesh

The LiDAR scanner on iPhone/iPad resolves depth at roughly 3–5mm at typical scanning
distance, and accuracy degrades further from the sensor. Custom orthotics generally need
sub-millimeter precision at a handful of specific points (arch peak, 1st/5th metatarsal
heads, heel center). Raw mesh geometry alone won't reliably hit that, which is why
commercial scanners (Aetrex Albert, Wiivv) lean on multi-angle photo capture and
computer vision rather than LiDAR depth alone.

The architecture here treats LiDAR mesh as a *fast, well-aligned scaffold* and uses a
trained ML model to recover precision at the landmarks that actually matter, rather than
trusting raw vertex positions. If you need higher fidelity than LiDAR alone provides,
swap Stage 1 for RealityKit's `ObjectCaptureSession` (photogrammetry, iOS 17+) — it works
on non-LiDAR devices too and produces meshes an order of magnitude more detailed, at the
cost of a slower, more guided capture flow (dozens of photos vs. one continuous LiDAR
pass).

## Tool stack

| Framework | Introduced | Role |
|---|---|---|
| ARKit (`sceneReconstruction`) | iOS 13.4 / ARKit 3.5 (2020) | Real-time LiDAR mesh anchors |
| RealityKit Object Capture | iOS 17 (2023) | Optional higher-fidelity photogrammetry capture, on-device |
| Model I/O | iOS 9+ | Mesh import/export (OBJ, USDZ); no native STL, so we write our own |
| Core ML / Create ML | iOS 11+ | On-device inference / model training (training happens on Mac) |
| RealityKit | iOS 13+ | Interactive 3D rendering, non-AR "model preview" camera mode |
| Accelerate / simd | — | Vector math for smoothing & measurements, pure Swift |

All of the above expose pure-Swift APIs — no Objective-C bridging headers required.

## Files

- `Sources/FootScanCapture.swift` — `ARSession` setup with `sceneReconstruction`,
  collects `ARMeshAnchor`s as the user moves the phone around the foot.
- `Sources/FootMeshProcessor.swift` — combines mesh anchors into one mesh, removes the
  floor plane, Laplacian smoothing, simple grid-based decimation, PCA-based bounding
  measurements (length/width/arch height) as a non-ML fallback.
- `Sources/FootLandmarkML.swift` — farthest-point sampling to a fixed-size point cloud,
  a `Core ML` wrapper for a trained landmark regression model, plus a pure-geometry
  fallback so the app works before you've trained a model.
- `Sources/InteractiveFootView.swift` — SwiftUI + RealityKit viewer in non-AR "model
  preview" mode, with pinch-to-zoom / pan-to-rotate gestures over the captured mesh.
- `Sources/MeshExporter.swift` — USDZ/OBJ export via Model I/O, plus a hand-rolled binary
  STL writer (STL is the format most orthotic manufacturing / 3D-printing pipelines
  expect, and Model I/O doesn't write it natively).

## ML model recommendations, in priority order

1. **Landmark regression** (highest value). Architecture: PointNet/PointNet++-style
   network, input = N=2048 sampled points (x,y,z) from the isolated foot mesh, output =
   5–7 landmark coordinates. Train in PyTorch or Create ML on a labeled scan dataset,
   convert with `coremltools`. This is the single highest-leverage ML addition — it's
   what turns "a mesh" into "a usable orthotic measurement."
2. **Foot/background segmentation**. Either a small point classifier or — cheaper to
   ship first — pure heuristics: ARKit plane classification removes the floor, then
   largest-connected-component clustering within an expected bounding volume isolates
   the foot. Only add a learned segmenter if the heuristic isn't robust enough for your
   capture environment (patterned floors, multiple objects in frame, etc.).
3. **Scan quality/completeness classifier**. Lightweight model or rule-based checks
   (coverage percentage, motion blur, frame confidence) that drive real-time capture
   guidance, similar to Object Capture's built-in coaching UI.
4. **Surface hole-filling**. Start classical (Poisson surface reconstruction or
   Laplacian smoothing, both non-ML and cheap). Only reach for a learned implicit-surface
   model if classical methods leave visible gaps after testing on real scans.

## A regulatory note

Depending on jurisdiction, an app that directly drives manufacturing of custom
orthotics may be considered a medical device (e.g. under FDA rules in the US). Worth
checking early — it affects validation requirements for the ML landmark model and what
claims you can make in-app, separate from the engineering work here.
