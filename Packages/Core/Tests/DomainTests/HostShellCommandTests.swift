import Foundation
import Testing
@testable import Domain

@Suite("Host shell command")
struct HostShellCommandTests {
    @Test func entersContainerOnTheConnectedNode() {
        #expect(HostShellCommand.enterContainer(vmid: 105, guestNode: "pve", hostNode: "pve", user: "root") == "pct enter 105")
    }

    @Test func hopsToTheGuestsNodeInACluster() {
        #expect(HostShellCommand.enterContainer(vmid: 105, guestNode: "pve2", hostNode: "pve", user: "root") == "ssh -t pve2 pct enter 105")
    }

    @Test func usesSudoForOtherUsers() {
        #expect(HostShellCommand.enterContainer(vmid: 105, guestNode: "pve", hostNode: "pve", user: "admin") == "sudo pct enter 105")
        #expect(HostShellCommand.enterContainer(vmid: 7, guestNode: "pve2", hostNode: "pve", user: "admin") == "sudo ssh -t pve2 pct enter 7")
    }

    @Test func unknownHostNodeStaysLocal() {
        #expect(HostShellCommand.enterContainer(vmid: 105, guestNode: "pve2", hostNode: nil, user: "root") == "pct enter 105")
    }
}

@Suite("Guest snapshot names")
struct GuestSnapshotNameTests {
    @Test func validatesProxmoxRules() {
        #expect(GuestSnapshotName.isValid("before_update"))
        #expect(GuestSnapshotName.isValid("v2-test"))
        #expect(!GuestSnapshotName.isValid("1abc"))
        #expect(!GuestSnapshotName.isValid("a"))
        #expect(!GuestSnapshotName.isValid("with space"))
        #expect(!GuestSnapshotName.isValid("ümlaut"))
        #expect(!GuestSnapshotName.isValid(String(repeating: "a", count: 41)))
    }

    @Test func suggestionIsValid() {
        let date = Date(timeIntervalSince1970: 1_794_384_000)
        let name = GuestSnapshotName.suggested(date: date)
        #expect(name.hasPrefix("before_update_"))
        #expect(GuestSnapshotName.isValid(name))
    }

    @Test func upgradeCommandFollowsTheUser() {
        #expect(HostShellCommand.upgradeHost(user: "root") == "apt update && apt full-upgrade")
        #expect(HostShellCommand.upgradeHost(user: "admin") == "sudo apt update && sudo apt full-upgrade")
    }
}
