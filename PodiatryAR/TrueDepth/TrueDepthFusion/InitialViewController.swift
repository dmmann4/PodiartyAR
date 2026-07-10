//
//  InitialViewController.swift
//  TrueDepthFusion
//
//  Created by Aaron Thompson on 11/7/18.
//

import Foundation
import UIKit

import UIKit

class LandingViewController: UIViewController {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "PodiatryAR"
        label.textColor = .white
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let startScanningButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Start Scanning", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = .darkGray
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.title = "Start Scanning"
            config.baseBackgroundColor = .darkGray
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
            button.configuration = config
        } else {
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        }
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        view.addSubview(titleLabel)
        view.addSubview(startScanningButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),

            startScanningButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startScanningButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 32)
        ])

        startScanningButton.addTarget(self, action: #selector(startScanningTapped), for: .touchUpInside)
    }

    @objc private func startScanningTapped() {
        // Hook up navigation to your scanning flow here
        print("Start Scanning tapped")
        let scanToBPLY = UserDefaults.standard.bool(forKey: "dump_raw_frames_to_bply", defaultValue: false)
        let segueIdentifier = scanToBPLY ? "BPLYScanningViewController" : "ScanningViewController"
        performSegue(withIdentifier: segueIdentifier, sender: nil)
    }
}

extension UserDefaults {
    
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        if let defaultNumber = object(forKey: key) as? NSNumber {
            return defaultNumber.boolValue
        } else {
            return defaultValue
        }
    }
    
}
