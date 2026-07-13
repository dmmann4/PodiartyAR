import SwiftUI

struct StartScanView: View {
    var body: some View {
        VStack {
            InitialStoryboardView()
                .ignoresSafeArea()
        }
        .navigationTitle("Start Scan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        StartScanView()
    }
}
