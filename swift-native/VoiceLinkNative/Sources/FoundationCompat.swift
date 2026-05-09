import Foundation

// Force the package to use Foundation's concrete types where symbol resolution
// has become ambiguous inside the target.
typealias UserDefaults = Foundation.UserDefaults
typealias OperationQueue = Foundation.OperationQueue
