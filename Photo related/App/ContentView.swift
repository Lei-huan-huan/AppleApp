//
//  ContentView.swift
//  Photo related
//
//  Created by 雷欢欢 on 2026/5/8.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                PhotoToolsHomeView()
            }
            .tabItem {
                Label("照片", systemImage: PhotoTab.photos.icon)
            }

            NavigationStack {
                VideoPlaybackHomeView()
            }
            .tabItem {
                Label("视频播放", systemImage: PhotoTab.categories.icon)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
