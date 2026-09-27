import Foundation
import Tx3SDK

let interface = """
    {
      "tii": {"version": "v1beta0"},
      "protocol": {"name": "consumer", "version": "0.15.0"},
      "parties": {},
      "profiles": {},
      "transactions": {
        "inspect": {
          "params": {"type": "object", "properties": {}, "required": []},
          "tir": {"encoding": "hex", "content": "00", "version": "v1beta0"}
        }
      }
    }
    """
let endpoint = URL(string: "https://trp.example/rpc")
guard let endpoint else {
    fatalError("The documented endpoint must be a valid URL")
}
let client = try Protocol.fromJSON(interface).client().trpEndpoint(endpoint).build()
_ = try client.tx("inspect")
print("Tx3SDK consumer is ready")
