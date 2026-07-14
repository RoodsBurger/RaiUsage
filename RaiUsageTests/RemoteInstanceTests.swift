import Testing
import Foundation

@Suite("RemoteInstance validation + model")
struct RemoteInstanceTests {

    // MARK: - Host validation

    @Test("accepts IPv4, hostnames, and IPv6 literals")
    func acceptsValidHosts() {
        #expect(RemoteInstanceValidation.isValidHost("10.63.7.150"))
        #expect(RemoteInstanceValidation.isValidHost("ec2-3-14-15-92.compute-1.amazonaws.com"))
        #expect(RemoteInstanceValidation.isValidHost("build-box_01"))
        #expect(RemoteInstanceValidation.isValidHost("fe80::1"))
        #expect(RemoteInstanceValidation.isValidHost("localhost"))
    }

    @Test("rejects hosts with spaces or shell metacharacters")
    func rejectsUnsafeHosts() {
        #expect(!RemoteInstanceValidation.isValidHost(""))
        #expect(!RemoteInstanceValidation.isValidHost("10.0.0.1 rm -rf /"))
        #expect(!RemoteInstanceValidation.isValidHost("host;reboot"))
        #expect(!RemoteInstanceValidation.isValidHost("host$(whoami)"))
        #expect(!RemoteInstanceValidation.isValidHost("host`id`"))
        #expect(!RemoteInstanceValidation.isValidHost("a&&b"))
        #expect(!RemoteInstanceValidation.isValidHost("a|b"))
        #expect(!RemoteInstanceValidation.isValidHost("host/../etc"))
        #expect(!RemoteInstanceValidation.isValidHost("host name"))
    }

    // MARK: - User validation

    @Test("accepts normal SSH usernames")
    func acceptsValidUsers() {
        #expect(RemoteInstanceValidation.isValidUser("ubuntu"))
        #expect(RemoteInstanceValidation.isValidUser("ec2-user"))
        #expect(RemoteInstanceValidation.isValidUser("deploy.bot_1"))
    }

    @Test("rejects users with metacharacters, spaces, or a colon")
    func rejectsUnsafeUsers() {
        #expect(!RemoteInstanceValidation.isValidUser(""))
        #expect(!RemoteInstanceValidation.isValidUser("root; echo"))
        #expect(!RemoteInstanceValidation.isValidUser("a b"))
        #expect(!RemoteInstanceValidation.isValidUser("user@host"))
        // Colon is allowed in hosts (IPv6) but never in users.
        #expect(!RemoteInstanceValidation.isValidUser("us:er"))
    }

    // MARK: - Display label rule

    @Test("displayLabel prefers a non-blank nickname, else user@host")
    func displayLabelRule() {
        let named = RemoteInstance(host: "10.0.0.1", user: "ubuntu", nickname: "prod-worker")
        #expect(named.displayLabel == "prod-worker")

        let blankNick = RemoteInstance(host: "10.0.0.1", user: "ubuntu", nickname: "   ")
        #expect(blankNick.displayLabel == "ubuntu@10.0.0.1")

        let noNick = RemoteInstance(host: "10.0.0.1", user: "ubuntu", nickname: nil)
        #expect(noNick.displayLabel == "ubuntu@10.0.0.1")
        #expect(noNick.sshTarget == "ubuntu@10.0.0.1")
    }

    @Test("RemoteInstance round-trips through Codable")
    func codableRoundTrip() throws {
        let original = RemoteInstance(host: "1.2.3.4", user: "ubuntu", enabled: false, nickname: "box")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteInstance.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - LogSource identity

    @Test("LogSource identity ignores the display label")
    func logSourceIdentityByID() {
        let id = UUID()
        #expect(LogSource.instance(id: id, label: "old") == LogSource.instance(id: id, label: "new"))
        #expect(LogSource.local != LogSource.instance(id: id, label: "x"))

        var set: Set<LogSource> = []
        set.insert(.instance(id: id, label: "old"))
        #expect(set.contains(.instance(id: id, label: "renamed")))
    }
}
