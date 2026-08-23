---
id: 2A20AADC-D81A-4A45-B96D-65005A02530E
created: 2026-03-16T11:29:08Z
modified: 2026-03-19T11:29:08Z
---
# Retro: the indexer

I keep meaning to write down how the indexer is actually wired, and keep not doing it. Certificates, tokens and clock skew: three explanations for the same symptom in the indexer.

Reading back through this, most of the confusion around the indexer is naming. Logs from the deploy are useless here — nothing about the indexer is written out at all.

Someone asked about the indexer in the channel and the answer was longer than it should be. The staging environment lies about the indexer, so measure on the real cluster.

