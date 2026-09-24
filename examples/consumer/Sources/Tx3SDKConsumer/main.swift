import Foundation
import Tx3SDK

let reference = UtxoRef(txId: Data(repeating: 0, count: 32), index: 0)
print(reference.index)
