//
//  PermissionStateView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import SwiftUI

struct PermissionStateView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.bold())

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
