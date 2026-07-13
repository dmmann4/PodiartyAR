//
//  ScanViewerViewController.swift
//  PodiatryAR
//
//  Created by Mann Fam on 7/12/26.
//


import UIKit
import SceneKit
import SceneKit.ModelIO

class ScanViewerViewController: UIViewController {

    var sceneView: SCNView!
    var plyFileURL: URL? // Pass your local .ply file URL here
    var pointCloudScene: SCNScene?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSceneView()
        
        if let scene = pointCloudScene {
            sceneView.scene = scene
        } else if let url = plyFileURL {
            displayPointCloud(from: url)
        }
    }

    private func setupSceneView() {
        sceneView = SCNView(frame: self.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = .black
        
        // Allows the user to rotate, pinch, and pan the point cloud instantly
        sceneView.allowsCameraControl = true 
        sceneView.autoenablesDefaultLighting = true
        
        self.view.addSubview(sceneView)
    }

    private func displayPointCloud(from url: URL) {
        // 1. Load the PLY file via ModelIO
        let asset = MDLAsset(url: url)
        let scene = SCNScene(mdlAsset: asset)
        
        // 2. Configure the material to draw points instead of solid triangles
        scene.rootNode.enumerateChildNodes { (node, _) in
            if let geometry = node.geometry {
                for material in geometry.materials {
                    // Crucial: Tells the GPU to render vertices as dots
                    material.fillMode = .lines 
                    
                    // Optional: Prevent lighting math from making points invisible
                    material.lightingModel = .constant 
                }
            }
        }
        
        // 3. Assign the configured scene to the view
        sceneView.scene = scene
    }
}
