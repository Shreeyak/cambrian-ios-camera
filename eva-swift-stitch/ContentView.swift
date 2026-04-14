//
//  ContentView.swift
//  eva-swift-stitch
//
//  Created by shrek on 4/14/26.
//

import SwiftUI
import AVFoundation


struct ContentView: View {
    @State private var permissionGranted = false

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(permissionGranted ? "Camera ready ✅" : "No camera access ❌")
                            .font(.title)
                        Button("Request Camera Permission") {
                            requestCameraPermission()
                        }
                        .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    func requestCameraPermission() {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    permissionGranted = granted
                }
            }
        }
}

#Preview {
    ContentView()
}
