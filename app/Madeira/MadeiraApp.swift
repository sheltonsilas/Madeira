import SwiftUI

@main
struct MadeiraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                }
                // Two kinds of URL reach an app this way, and until now only one
                // of them was handled at all:
                //
                //   madeira://jit-network/...  the JIT shortcut returning
                //                              (JITNetwork.swift)
                //   file://...                 an installer iOS opened WITH
                //                              Madeira - a download tapped in
                //                              Files, a share-sheet target.
                //                              Info.plist is what makes iOS offer
                //                              Madeira for those; this is what runs
                //                              them once it does.
                .onOpenURL { url in
                    if url.isFileURL {
                        IncomingInstaller.shared.handle(url)
                    } else {
                        JITNetworkShortcut.shared.handle(url)
                    }
                }
        }
    }
}
