import SwiftUI

struct ContentView: View {
    @State private var session = TerrainSession()
    var body: some View {
        TerrainMapView(session: session)
    }
}
