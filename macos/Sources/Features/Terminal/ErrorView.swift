import SwiftUI

struct ErrorView: View {
    var body: some View {
        HStack {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)

            VStack(alignment: .leading) {
                Text("Oh, no. 😭").font(.title)
                Text("Something went fatally wrong.\nCheck the logs and restart Ghostties.")
            }
        }
        .padding()
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ErrorView()
    }
}
