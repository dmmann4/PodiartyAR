import SwiftUI

struct ContentView: View {
    
@State var showSplash: Bool = true
    
var body: some View {
    ZStack {
        if showSplash {
            SplashScreenView()
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showSplash = false
                    }
                }
            .transition(.opacity)
            .zIndex(1)
        } else {
            HomeView()
                .transition(.opacity)
        }
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

struct HomeView: View {

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center) {
                    Image("3dFormulaLogo")
                        .resizable()
                        .frame(width: 350, height: 400)

                    VStack(alignment: .leading) {
                        VStack(spacing: 16) {
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
                    }
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("")
        }
        .tint(.brandTeal)
    }
}

#Preview {
    HomeView()
}
