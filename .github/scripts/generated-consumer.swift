import Foundation
import Tx3SDK
import UnknownClient

guard let endpoint = URL(string: "https://trp.example/rpc") else {
    fatalError("The documented endpoint must be a valid URL")
}
let options = ClientOptions(endpoint: endpoint)
let client = UnknownClient(options: options, profile: .preprod)
    .withSender(.address(try Address("00")))
    .withReceiver(.address(try Address("11")))
    .withMiddleman(.address(try Address("22")))
_ = client.transfer(TransferParams(quantity: 10_000_000))
print("Generated client consumer is ready")
