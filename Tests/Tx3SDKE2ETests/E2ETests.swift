import Foundation
import Testing

@testable import Tx3SDK

private struct E2EConfigurationError: Error, CustomStringConvertible {
    let missing: [String]

    var description: String {
        "Missing required e2e configuration: \(missing.joined(separator: ", "))"
    }
}

private struct E2EConfiguration {
    static let requiredNames = [
        "TRP_ENDPOINT_PREPROD",
        "TRP_API_KEY_PREPROD",
        "TEST_PARTY_A_ADDRESS",
        "TEST_PARTY_A_MNEMONIC",
        "TEST_PARTY_B_ADDRESS",
        "TEST_PARTY_B_MNEMONIC",
    ]

    let endpoint: URL
    let apiKey: String
    let partyAAddress: Address
    let partyAMnemonic: String
    let partyBAddress: Address
    let partyBMnemonic: String

    static func load() throws -> E2EConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let missing = requiredNames.filter { environment[$0, default: ""].isEmpty }
        guard missing.isEmpty else {
            if environment["CI"] == "true" {
                throw E2EConfigurationError(missing: missing)
            }
            print("Skipping live e2e tests; missing: \(missing.joined(separator: ", "))")
            return nil
        }

        guard let endpoint = URL(string: environment["TRP_ENDPOINT_PREPROD", default: ""]) else {
            throw E2EConfigurationError(missing: ["valid TRP_ENDPOINT_PREPROD"])
        }
        return try E2EConfiguration(
            endpoint: endpoint,
            apiKey: environment["TRP_API_KEY_PREPROD", default: ""],
            partyAAddress: Address(environment["TEST_PARTY_A_ADDRESS", default: ""]),
            partyAMnemonic: environment["TEST_PARTY_A_MNEMONIC", default: ""],
            partyBAddress: Address(environment["TEST_PARTY_B_ADDRESS", default: ""]),
            partyBMnemonic: environment["TEST_PARTY_B_MNEMONIC", default: ""]
        )
    }
}

@Suite("Tx3 SDK end-to-end", .serialized)
struct E2ETests {
    @Test("canonical transfer completes the confirmed and finalized lifecycle")
    func transferLifecycle() async throws {
        guard let configuration = try E2EConfiguration.load() else { return }
        let client = try Self.client(configuration)

        let resolved =
            try await client
            .tx("transfer")
            .arg("quantity", 10_000_000)
            .resolve()
        let submitted = try await resolved.sign().submit()
        let polling = try PollConfig(attempts: 40, delay: .seconds(5))

        let confirmed = try await submitted.waitForConfirmed(polling)
        #expect(confirmed.stage == .confirmed || confirmed.stage == .finalized)
        let finalized = try await submitted.waitForFinalized(polling)
        #expect(finalized.stage == .finalized)
    }

    @Test("spec errors remain typed")
    func specificationErrors() async throws {
        guard let configuration = try E2EConfiguration.load() else { return }
        let client = try Self.client(configuration)

        await #expect(throws: Tx3Error.resolution(.missingParameter(name: "quantity"))) {
            try await client.tx("transfer").resolve()
        }

        let unreachable = try Self.client(configuration, endpoint: Self.unreachableEndpoint)
        do {
            _ = try await unreachable.tx("transfer").arg("quantity", 1).resolve()
            Issue.record("An unreachable TRP endpoint must report a transport failure")
        } catch Tx3Error.transport {
        } catch {
            Issue.record("Expected Tx3Error.transport, got \(error)")
        }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tx3SDKTests/Fixtures/transfer.tii")
    }

    private static var unreachableEndpoint: URL {
        guard let url = URL(string: "http://127.0.0.1:1") else {
            preconditionFailure("Static unreachable endpoint must be valid")
        }
        return url
    }

    private static func client(
        _ configuration: E2EConfiguration,
        endpoint: URL? = nil
    ) throws -> Tx3Client {
        let signer = try CardanoSigner(
            mnemonic: configuration.partyAMnemonic,
            address: configuration.partyAAddress
        )
        _ = try CardanoSigner(
            mnemonic: configuration.partyBMnemonic,
            address: configuration.partyBAddress
        )
        return try Protocol.fromFile(fixtureURL)
            .client()
            .trp(
                ClientOptions(
                    endpoint: endpoint ?? configuration.endpoint,
                    headers: ["dmtr-api-key": configuration.apiKey],
                    timeout: .seconds(30)
                )
            )
            .withProfile("preprod")
            .withParty("sender", .signer(signer))
            .withParty("receiver", .address(configuration.partyBAddress))
            .withParty("middleman", .address(configuration.partyBAddress))
            .build()
    }
}
