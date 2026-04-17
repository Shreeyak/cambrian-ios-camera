import SwiftUI
import AVFoundation


struct ContentView: View {
    @State private var permissionGranted = false
    @State private var reportText: String = ""
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button("Request Camera Permission") {
                    requestCameraPermission()
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissionGranted)

                Button(isRunning ? "Running…" : "Report Capabilities") {
                    runCapabilitiesReport()
                }
                .buttonStyle(.bordered)
                .disabled(!permissionGranted || isRunning)
            }
            .padding(.top)

            Text(permissionGranted ? "Camera permission granted" : "No camera access")
                .font(.caption)
                .foregroundStyle(permissionGranted ? .green : .red)

            if !reportText.isEmpty {
                ScrollView {
                    Text(reportText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }
        }
        .padding()
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                permissionGranted = granted
            }
        }
    }

    private func runCapabilitiesReport() {
        isRunning = true
        reportText = ""
        Task.detached(priority: .userInitiated) {
            let result = CameraCapabilitiesReporter.report()
            await MainActor.run {
                reportText = result
                isRunning = false
            }
        }
    }
}

#Preview {
    ContentView()
}
