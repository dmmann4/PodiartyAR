// ViewControllerSwiftUIWrapper.swift
// Wraps ViewController for use in SwiftUI

import SwiftUI

struct InitialStoryboardView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: nil) 
        return storyboard.instantiateInitialViewController()!
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
