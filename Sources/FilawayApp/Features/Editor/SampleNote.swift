import Foundation

/// The in-memory note the demo shell shows until storage (M1-03) and the real
/// sidebar (M1-09) land. Mirrors spec Figure 1 plus the other block types the
/// editor styles, so `make run` is also a visual check.
enum SampleNote {

    static let title = "Untitled note"

    static let createdAt: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 22
        components.hour = 9
        components.minute = 41
        return Calendar.current.date(from: components) ?? Date()
    }()

    static let markdown = """
    curl to fetch docs from staging:

    ```bash
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```

    remember: token expires hourly

    ## Follow-ups

    - [ ] rotate the staging token
    - [x] check `TTL` on the *refresh* endpoint
    - see the [runbook](https://wiki.internal/runbooks/staging)

    1. request a token
    2. export it as **TOK**
    3. run the command above

    > staging mirrors prod nightly at 02:00 UTC

    ```swift
    let response = try await client.fetchDocs(token: token)
    print(response.items.count)
    ```

    """
}
