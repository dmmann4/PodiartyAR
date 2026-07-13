//
//  ShareSheet.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/12/26.
//


import SwiftUI
import UIKit

/// Thin wrapper around UIActivityViewController so we can present the
/// standard iOS share sheet (Save to Files, AirDrop, Mail, etc.) for a
/// generated export file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}