    private var currentServerURL: String = ""
    private var useMainServer: Bool = true

    // Public accessor for the current server URL
    var baseURL: String? {
        currentServerURL.isEmpty ? nil : currentServerURL
    }
