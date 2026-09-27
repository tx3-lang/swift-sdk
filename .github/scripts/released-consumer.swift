import Foundation
import Tx3SDK

let reference = UtxoRef(txId: Data(repeating: 0, count: 32), index: 0)
print("Released Tx3SDK consumer is ready at input index \(reference.index)")
