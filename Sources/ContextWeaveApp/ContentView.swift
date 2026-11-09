import SwiftUI
import ContextWeaveCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("ContextWeave")
                .font(.largeTitle.weight(.semibold))
            Text("welcome.tagline", bundle: .module)
                .foregroundStyle(.secondary)
            Text("welcome.status", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
