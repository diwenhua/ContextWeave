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
            Text("让每个 Agent，都接得上你的工作。")
                .foregroundStyle(.secondary)
            Text("应用骨架已就绪。会话采集、搜索与交接功能将在后续加入。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
