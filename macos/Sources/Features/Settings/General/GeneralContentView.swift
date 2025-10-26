import SwiftUI

struct GeneralContentView: View {
    @EnvironmentObject var config: Ghostty.ConfigFile
    @State private var updateChannel: Ghostty.AutoUpdateChannel = .stable
    var body: some View {
        Form {
            Section {
                Picker("Update Channel", selection: $updateChannel) {
                    ForEach(Ghostty.AutoUpdateChannel.allCases) { chanel in
                        Text(chanel.description).tag(chanel)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: updateChannel) { newValue in
            config.updateChannel = newValue
        }
        .task {
            updateChannel = config.updateChannel
        }
    }
}
