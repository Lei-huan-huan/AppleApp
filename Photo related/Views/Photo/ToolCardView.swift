//
//  ToolCardView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import SwiftUI

struct ToolCardView: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
