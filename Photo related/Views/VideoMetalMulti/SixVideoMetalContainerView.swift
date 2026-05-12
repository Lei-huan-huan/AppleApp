//
//  SixVideoMetalContainerView.swift
//  Photo related
//

import SwiftUI
import UIKit

struct SixVideoMetalContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SixVideoHostViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class SixVideoHostViewController: UIViewController {
    private let contentViewController = SixVideoViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        addChild(contentViewController)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentViewController.view)
        NSLayoutConstraint.activate([
            contentViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        contentViewController.didMove(toParent: self)

        contentViewController.loadViewIfNeeded()
        title = contentViewController.title
    }
}
