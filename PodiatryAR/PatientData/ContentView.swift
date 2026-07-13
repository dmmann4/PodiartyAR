import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                Text("Podiatry Scan")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                HStack(spacing: 16) {
                    NavigationLink {
                        NewPatientFormView()
                    } label: {
                        HomeButtonLabel(title: "New Patient", systemImage: "person.badge.plus")
                    }

                    NavigationLink {
                        LoadPatientView()
                    } label: {
                        HomeButtonLabel(title: "Load Patient", systemImage: "folder")
                    }

                    NavigationLink {
                        StartScanView()
                    } label: {
                        HomeButtonLabel(title: "Start Scan", systemImage: "camera.viewfinder")
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding()
        }
    }
}

/// Shared look for the three home screen buttons so they stay equal width and stack cleanly.
private struct HomeButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.accentColor.opacity(0.1))
        .foregroundStyle(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}
