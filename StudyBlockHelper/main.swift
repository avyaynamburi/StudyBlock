import Foundation
import os

let logger = Logger(subsystem: "com.avyay.studyblock.helper", category: "main")

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // TODO(hardening): verify the connecting client's code signature via
        // the audit token before accepting. Fine to skip for personal use, but
        // required before distributing: as written, any local process can ask
        // this root daemon to edit /etc/hosts.
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

logger.info("StudyBlock helper \(StudyBlockShared.helperVersion) starting")

// Re-arm a locked session that was running before a restart/reboot, or clean
// up after one that expired while the helper was down.
LockManager.shared.resumeAfterLaunch()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: StudyBlockShared.machServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
