---
id: C98CB850-484F-457E-AE87-ECCFA8F587BD
created: 2026-05-15T10:39:37Z
modified: 2026-05-23T10:39:37Z
---
# Thinking about the indexer

Every time the token expires I go looking for the same thing about the indexer. The indexer came up again and nobody could remember what we decided last time.

Rebasing this branch was fine; it is the indexer that made the review painful. The docs for the indexer describe the version before last, which cost me an hour.

I keep meaning to write down how the indexer is actually wired, and keep not doing it. I want a note that just holds the command, not an essay about the indexer.

## Leftovers

Half of this is going to be wrong in a month, like everything about the indexer.

Certificates, tokens and clock skew: three explanations for the same symptom in the indexer. The container starts, the pod is ready, and the indexer is still wrong.

The thing I actually needed was two directories up, filed under the indexer. There is a curl invocation somewhere in my history that would settle this about the indexer.

