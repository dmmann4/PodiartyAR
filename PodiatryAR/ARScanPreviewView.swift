import SwiftUI
import ARKit
import SceneKit

/// Live camera preview during scanning, with the in-progress LiDAR mesh drawn as a
/// wireframe overlay (ARSCNDebugOptions.showSceneUnderstanding) so the person
/// scanning can see what's already been captured.
///
/// Uses ARSCNView rather than RealityKit's ARView specifically because ARSCNView's
/// `session` property is settable — it lets us bind to the exact ARSession instance
/// FootScanCapture already configured and is running, instead of owning a second one.
struct ARScanPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ScanningView: View {
    @ObservedObject var capture: FootScanCapture
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            ARScanPreviewView(session: capture.session)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 14) {
                    Text(capture.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    ProgressView(value: capture.coveragePercent)
                        .tint(.white)
                        .frame(maxWidth: 240)

                    Button(action: onFinish) {
                        Text("Done scanning")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }
}
