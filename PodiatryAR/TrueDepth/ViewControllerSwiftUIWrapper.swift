// ViewControllerSwiftUIWrapper.swift
// Wraps ViewController for use in SwiftUI

import SwiftUI

struct ViewControllerWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        // Assumes ViewController is the initial view controller in Main.storyboard,
        // or update the identifier as needed.
        guard let vc = storyboard.instantiateInitialViewController() as? ViewController else {
            fatalError("Failed to instantiate ViewController from Main.storyboard")
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
        // No-op: Add data binding logic here if needed for SwiftUI interop
    }
}

// Usage Example in SwiftUI:
// struct ContentView: View {
//     var body: some View {
//         ViewControllerWrapper()
//             .edgesIgnoringSafeArea(.all)
//     }
// }
