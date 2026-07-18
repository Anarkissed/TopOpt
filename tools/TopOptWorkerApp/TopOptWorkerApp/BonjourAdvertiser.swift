// BonjourAdvertiser — advertises the running worker on the LAN as `_topopt._tcp`
// so the iPad discovers "this Mac" BY NAME (never an IP). The Python worker owns
// the TCP socket; NetService just publishes the DNS-SD record pointing at its
// port, with the core fingerprint in the TXT record so the iPad can show version
// skew BEFORE submitting a run (handoff 097).
//
// NetService (vs NWListener) is deliberate: NWListener would open its OWN socket,
// but the socket is already owned by the worker. NetService advertises a service
// implemented by a separate process without binding — exactly this case.

import Foundation

final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    /// (Re)publish `_topopt._tcp` on `port`, TXT carrying the core `fingerprint`.
    func publish(port: Int, fingerprint: String) {
        stop()
        // The instance name is the Mac's name — the label the iPad picker shows.
        let name = Host.current().localizedName ?? "TopOpt Worker"
        let svc = NetService(domain: "local.", type: "_topopt._tcp.",
                             name: name, port: Int32(port))
        svc.delegate = self
        var txt: [String: Data] = [:]
        txt["fingerprint"] = Data(fingerprint.utf8)
        txt["worker"] = Data("topopt".utf8)
        _ = svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.schedule(in: .main, forMode: .common)
        svc.publish()
        service = svc
    }

    func stop() {
        service?.stop()
        service = nil
    }

    // MARK: NetServiceDelegate (diagnostics only)

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("TopOpt Worker: advertising _topopt._tcp \"%@\" on port %d",
              sender.name, sender.port)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("TopOpt Worker: Bonjour publish failed: %@", errorDict)
    }
}
