import Foundation

/// The hand-curated half of the M3-07 development corpus.
///
/// Every entry here is a note a developer would plausibly have written: a
/// sentence or two of context, the command that was actually run, and what to
/// remember about it. The `Tests/Fixtures/queries/dev.json` query set points at
/// these by path and by a substring of the fenced block — that substring is the
/// **answer** FR-5.2 promises, so it has to be unique across the whole corpus
/// (`RetrievalFixtureTests` asserts exactly that).
///
/// Curation happens *here*, not in the generated Markdown: edit the table, run
/// `filaway-bench corpus generate`, commit the diff.
enum DevCorpusContent {
    /// One golden note.
    struct Golden {
        /// Folder under the library root; at most two levels (`PathRules`).
        let folder: String
        let title: String
        /// Days before ``DevCorpus/referenceNow`` — the note's mtime, which is
        /// what every FR-5.3 temporal query filters on.
        let day: Int
        let tags: [String]
        /// Prose before the command. This is what a paraphrase query has to
        /// match when the query never names the tool.
        let lead: String
        let language: String
        let command: String
        /// Prose after the command — the "remember this" half of a real note.
        let trailer: String

        var relativePath: String {
            PathRules.relativePath(folder: folder, title: PathRules.sanitizeTitle(title))
        }

        var body: String {
            """
            # \(title)

            \(lead)

            ```\(language)
            \(command)
            ```

            \(trailer)
            """
        }
    }

    // MARK: - curl

    static let curl: [Golden] = [
        Golden(
            folder: "Commands/curl", title: "Staging docs endpoint", day: 34, tags: ["curl", "staging"],
            lead: """
            Spent twenty minutes getting 401s from the staging gateway before I noticed it wants \
            the bearer token *and* a tenant header — the production gateway infers the tenant from \
            the key, staging does not. This is the invocation that finally returned documents.
            """,
            language: "sh",
            command: """
            curl -sS -H "Authorization: Bearer $STAGING_TOKEN" -H "X-Tenant: acme" \\
              "https://staging.internal.example/api/v2/documents?limit=50" | jq '.items[]'
            """,
            trailer: """
            The token lives for an hour; mint a new one with the client-credentials call in the \
            auth debugging note. Without `-sS` curl hides the error body behind a progress meter.
            """
        ),
        Golden(
            folder: "Commands/curl", title: "Uploading an asset by hand", day: 61, tags: ["curl"],
            lead: """
            The web uploader was broken during the release freeze, so the cover images went up \
            from the terminal. Multipart, one field for the file and one for the kind.
            """,
            language: "sh",
            command: """
            curl -sS -X POST -H "Authorization: Bearer $ASSET_TOKEN" \\
              -F "file=@cover.png" -F "kind=thumbnail" https://assets.internal.example/v1/upload
            """,
            trailer: """
            The `@` is what makes it read the file rather than send the literal name. Anything \
            over 8 MB is rejected by the edge before the service sees it.
            """
        ),
        Golden(
            folder: "Commands/curl", title: "Making a flaky endpoint behave", day: 88, tags: ["curl"],
            lead: """
            The health endpoint drops roughly one request in five while the pool warms up, which \
            made the deploy script fail for no reason. Rather than wrap it in a shell loop I let \
            curl do the retrying, including on connection resets, which it will not do by default.
            """,
            language: "sh",
            command: """
            curl --retry 5 --retry-all-errors --retry-delay 2 --max-time 30 -sS https://flaky.internal.example/health
            """,
            trailer: """
            `--retry` alone only retries transient HTTP statuses; the reset was a transport error, \
            which is what `--retry-all-errors` covers. Always pair it with a total timeout.
            """
        ),
        Golden(
            folder: "Commands/curl", title: "Where does this old link go", day: 105, tags: ["curl"],
            lead: """
            Auditing the redirect table after the docs move. I wanted the final status and the \
            next hop and nothing else — no body, no progress bar, no headers dumped to the screen.
            """,
            language: "sh",
            command: """
            curl -sSIL -o /dev/null -w '%{http_code} %{redirect_url}\\n' https://example.com/old-path
            """,
            trailer: """
            `-I` asks for HEAD, `-L` follows the chain, and `-w` prints exactly the two fields I \
            care about. A 308 with an empty redirect target means the chain ended there.
            """
        ),
        Golden(
            folder: "Commands/curl", title: "Replaying a webhook event", day: 47, tags: ["curl", "webhooks"],
            lead: """
            A customer's event was dropped when the receiver restarted. I saved the payload the \
            provider had logged and pushed it back through by hand rather than asking them to \
            resend, which would have re-run their whole retry schedule.
            """,
            language: "sh",
            command: """
            curl -sS -X POST -H 'Content-Type: application/json' \\
              --data-binary @webhook-payload.json https://hooks.internal.example/v1/events
            """,
            trailer: """
            `--data-binary` rather than `-d`: plain `-d` strips newlines, and the signature is \
            computed over the exact bytes, so a stripped payload fails verification every time.
            """
        ),
        Golden(
            folder: "Commands/curl", title: "Where the request time goes", day: 73, tags: ["curl", "performance"],
            lead: """
            The mobile team said the ping endpoint felt slow from Europe. Before blaming the \
            service I wanted the breakdown — name lookup, connect, and how long until the first \
            byte of the response actually arrives.
            """,
            language: "sh",
            command: """
            curl -o /dev/null -sS -w 'dns=%{time_namelookup} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\\n' https://api.internal.example/v2/ping
            """,
            trailer: """
            It was DNS: 380 ms of the 500 ms was name resolution against a resolver in the wrong \
            region. The service itself answered in 40 ms.
            """
        ),
    ]

    // MARK: - git

    static let git: [Golden] = [
        Golden(
            folder: "Commands/git", title: "Rebasing onto main without losing work", day: 29, tags: ["git"],
            lead: """
            My branch was forty commits behind and a merge would have made the history unreadable. \
            The thing that made this safe rather than frightening is that every commit is still \
            reachable afterwards, so a mistake costs a lookup and not a day.
            """,
            language: "sh",
            command: """
            git fetch origin
            git rebase origin/main
            git reflog --date=iso | head -20
            """,
            trailer: """
            If a conflict turns out to be a mess, `git rebase --abort` puts everything back \
            exactly as it was. The reflog line is the safety net: every pre-rebase tip is still \
            listed there for ninety days, so nothing is ever actually lost.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Bisecting the slow test", day: 37, tags: ["git", "testing"],
            lead: """
            The scale suite went from four seconds to nineteen somewhere in the last two hundred \
            commits and nobody noticed. Rather than read the diff I let git binary-search it, \
            running the suite at each step and letting the exit status decide the direction.
            """,
            language: "sh",
            command: """
            git bisect start HEAD v1.8.0
            git bisect run swift test --filter SearchScaleTests
            git bisect reset
            """,
            trailer: """
            Eight steps, four minutes, and it landed on the commit that added a per-row path \
            normalisation. `git bisect run` needs the script to exit non-zero for "bad" — a test \
            runner already does.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Getting a deleted branch back", day: 52, tags: ["git"],
            lead: """
            I pruned merged branches with a script that was a little too enthusiastic and took a \
            branch that had never been merged with it. The commits were still there; only the \
            name was gone, and the name is the cheap part to restore.
            """,
            language: "sh",
            command: """
            git reflog --all | grep -i 'checkout: moving from feature/answer-card'
            git branch feature/answer-card 9f2c1ab
            """,
            trailer: """
            Find the last SHA the branch pointed at in the reflog, then point a fresh branch at \
            it. Garbage collection would eventually have taken them, which is why this is a \
            same-day fix and not a next-month one.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Tidying a branch before review", day: 66, tags: ["git"],
            lead: """
            Fourteen commits, eleven of them "wip" and "fix typo". The reviewer wants three \
            commits that each do one thing, so the branch gets squashed before it goes up.
            """,
            language: "sh",
            command: """
            git rebase -i HEAD~4
            git push --force-with-lease origin feature/chunker
            """,
            trailer: """
            `--force-with-lease` rather than `--force`: it refuses if someone else pushed to the \
            branch in the meantime, which is the only thing that makes force-pushing a shared \
            branch survivable.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Hotfix onto the release branch", day: 19, tags: ["git", "release"],
            lead: """
            The null-check fix landed on main, but 1.4 is cut and only takes fixes. One commit, \
            copied across, with a reference back to where it came from so the release notes can \
            be generated later.
            """,
            language: "sh",
            command: """
            git cherry-pick -x 4c9e02f
            git push origin release/1.4
            """,
            trailer: """
            The `-x` appends "(cherry picked from commit …)" to the message. Without it, working \
            out months later whether a fix is on both branches means diffing trees.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Who introduced this line", day: 95, tags: ["git"],
            lead: """
            Trying to work out why the recency multiplier is capped where it is. The comment says \
            nothing useful, so the answer is in the commit that introduced the constant, not in \
            the file as it stands.
            """,
            language: "sh",
            command: """
            git log -S 'recencyPrior' --oneline -- Sources/FilawayCore/Search
            git blame -L 120,160 Sources/FilawayCore/Search/HybridSearch.swift
            """,
            trailer: """
            `-S` searches for commits that changed the *number of occurrences* of a string, which \
            finds the introduction rather than every commit that touched the file.
            """
        ),
        Golden(
            folder: "Commands/git", title: "Undoing something already pushed", day: 112, tags: ["git"],
            lead: """
            A commit went to main that should not have. Rewriting shared history would have \
            broken everyone's checkout, so the fix is a new commit that undoes the old one.
            """,
            language: "sh",
            command: """
            git revert --no-edit 7a31c9d
            """,
            trailer: """
            Reverting a merge needs `-m 1` to say which parent is the mainline. For an ordinary \
            commit this is all it takes, and the history stays honest about what happened.
            """
        ),
    ]

    // MARK: - docker

    static let docker: [Golden] = [
        Golden(
            folder: "Commands/docker", title: "Rebuild one service and watch it", day: 8, tags: ["docker"],
            lead: """
            Iterating on the API container. Bringing the whole stack down and up again takes two \
            minutes; rebuilding the single service that changed and then following its output \
            takes fifteen seconds and shows me the stack trace immediately.
            """,
            language: "sh",
            command: """
            docker compose up -d --build api && docker compose logs -f --tail=100 api
            """,
            trailer: """
            `--tail=100` so the scrollback starts with the boot sequence rather than replaying the \
            whole day. Ctrl-C stops following without stopping the container.
            """
        ),
        Golden(
            folder: "Commands/docker", title: "A shell inside the running container", day: 41, tags: ["docker"],
            lead: """
            The config the service is actually using did not match the config in the repo, and the \
            only way to settle it was to look at the filesystem the process sees.
            """,
            language: "sh",
            command: """
            docker exec -it filaway-api-1 /bin/bash
            """,
            trailer: """
            Alpine-based images have no bash — use `/bin/sh` there. `-it` is what gives you a \
            usable terminal rather than a hung, echo-less prompt.
            """
        ),
        Golden(
            folder: "Commands/docker", title: "Reclaiming the disk docker ate", day: 57, tags: ["docker"],
            lead: """
            Forty gigabytes gone and the build failing with no space left. Most of it was dangling \
            build layers and volumes from throwaway database containers that were never cleaned up.
            """,
            language: "sh",
            command: """
            docker system prune -af --volumes
            docker builder prune --filter 'until=168h'
            """,
            trailer: """
            `--volumes` is the flag that actually frees the bulk, and the flag that will delete \
            data you meant to keep — check `docker volume ls` first if anything local matters.
            """
        ),
        Golden(
            folder: "Commands/docker", title: "Getting a file out of a container", day: 78, tags: ["docker"],
            lead: """
            The crash log only exists inside the container and the container is about to be \
            recycled by the restart policy, so it needs to be on my machine before that happens.
            """,
            language: "sh",
            command: """
            docker cp filaway-api-1:/var/log/app/error.log ./error.log
            """,
            trailer: """
            Works in both directions and works on a stopped container too, which matters when the \
            thing you want to examine is why it stopped.
            """
        ),
        Golden(
            folder: "Commands/docker", title: "A throwaway postgres for tests", day: 24, tags: ["docker", "postgres"],
            lead: """
            The integration suite wants a real database, not a fake, but nothing about it should \
            survive the run or collide with the one brew is already running on 5432.
            """,
            language: "sh",
            command: """
            docker run --rm -d --name pgtest -e POSTGRES_PASSWORD=devonly -p 55432:5432 postgres:16
            """,
            trailer: """
            `--rm` removes the container when it stops, so nothing accumulates. The password is \
            deliberately worthless — this container is never reachable off the machine.
            """
        ),
        Golden(
            folder: "Commands/docker", title: "What is this container mounting", day: 99, tags: ["docker"],
            lead: """
            A file the service writes was not showing up on the host, which usually means the \
            volume is not mounted where the compose file claims it is.
            """,
            language: "sh",
            command: """
            docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\\n"}}{{end}}' filaway-api-1
            """,
            trailer: """
            The Go template beats piping the whole JSON blob through a parser when all you want is \
            two fields. It was an anonymous volume shadowing the bind mount.
            """
        ),
    ]

    // MARK: - kubernetes

    static let kubernetes: [Golden] = [
        Golden(
            folder: "Commands/k8s", title: "Streaming logs from the api pod", day: 1, tags: ["kubernetes"],
            lead: """
            Watching a deploy go out. I want the output of the app container only — the sidecar is \
            noisy — and only the recent past, because the pod has been up for days.
            """,
            language: "sh",
            command: """
            kubectl logs -f deploy/api -c app --since=15m -n staging
            """,
            trailer: """
            Pointing at the deployment rather than a pod name means it keeps working after a \
            rollout replaces the pod. Add `--previous` to read the log of a container that crashed.
            """
        ),
        Golden(
            folder: "Commands/k8s", title: "Reaching the staging database", day: 15, tags: ["kubernetes", "postgres"],
            lead: """
            The database has no external address, on purpose. To point a local client at it I \
            forward the service port to a spare port on the laptop for as long as the command runs.
            """,
            language: "sh",
            command: """
            kubectl port-forward -n staging svc/postgres 55433:5432
            """,
            trailer: """
            Forward the *service*, not a pod, so a restart does not silently leave you connected \
            to nothing. It dies with the terminal, which is the right default for this.
            """
        ),
        Golden(
            folder: "Commands/k8s", title: "Rolling back a bad deploy", day: 33, tags: ["kubernetes", "release"],
            lead: """
            Error rate went vertical ninety seconds after the deploy. Rolling forward with a fix \
            would have taken twenty minutes of CI; going back to the previous replica set took one \
            command and about fifteen seconds.
            """,
            language: "sh",
            command: """
            kubectl rollout undo deploy/api -n staging
            kubectl rollout status deploy/api -n staging
            """,
            trailer: """
            `rollout status` blocks until the new pods are actually ready, so it is the line to put \
            in a script. Only the last ten revisions are kept by default.
            """
        ),
        Golden(
            folder: "Commands/k8s", title: "What environment does this pod see", day: 69, tags: ["kubernetes"],
            lead: """
            The config map was updated but the behaviour did not change, which usually means the \
            pod was never restarted and is still holding the old values in its environment.
            """,
            language: "sh",
            command: """
            kubectl exec -it -n staging deploy/api -- sh -lc 'env | sort'
            """,
            trailer: """
            The `--` separates kubectl's flags from the command; without it the flags after it get \
            eaten. Sorting makes the diff against the expected set readable.
            """
        ),
        Golden(
            folder: "Commands/k8s", title: "Finding the pod that keeps dying", day: 44, tags: ["kubernetes"],
            lead: """
            Something in the namespace was restarting in a loop and the dashboard was down. \
            Listing everything that is not currently running narrows it to one pod immediately, \
            and the events at the bottom of the description say why.
            """,
            language: "sh",
            command: """
            kubectl get pods -n staging --field-selector=status.phase!=Running
            kubectl describe pod api-7f9c5d8b6-2xkqz -n staging | sed -n '/Events/,$p'
            """,
            trailer: """
            It was an OOMKill: the memory limit was set from a measurement taken before the vector \
            matrix was loaded eagerly. Events are only kept for an hour, so look early.
            """
        ),
        Golden(
            folder: "Commands/k8s", title: "Getting a heap dump off a pod", day: 86, tags: ["kubernetes"],
            lead: """
            The dump is 900 MB inside a container with no shell tools and no network egress, so it \
            has to come out through the API server rather than over scp.
            """,
            language: "sh",
            command: """
            kubectl cp staging/api-7f9c5d8b6-2xkqz:/tmp/heap.hprof ./heap.hprof
            """,
            trailer: """
            It needs `tar` present in the container image, which is easy to forget when the base \
            is distroless. Slow, but it does not need anything opened up.
            """
        ),
    ]

    // MARK: - shell one-liners

    static let shell: [Golden] = [
        Golden(
            folder: "Commands/shell", title: "Pulling the ids out of the export", day: 5, tags: ["jq"],
            lead: """
            Support sent a 40 MB export and asked which records were still live. I only needed the \
            identifiers of the active ones, one per line, so the next script could read them.
            """,
            language: "sh",
            command: """
            jq -r '.data.items[] | select(.status == "active") | .id' export.json > ids.txt
            """,
            trailer: """
            `-r` drops the quotes, which is the difference between a usable list and a file the \
            next tool chokes on. 12,400 rows in, 3,180 out.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Adding up the response sizes", day: 63, tags: ["awk", "logs"],
            lead: """
            The egress bill jumped and I wanted to know how much of it was successful responses \
            before going anywhere near the provider's console.
            """,
            language: "sh",
            command: """
            awk '$9 == 200 { total += $10 } END { printf "%.1f MB\\n", total/1048576 }' access.log
            """,
            trailer: """
            Field nine is the status and ten is the byte count in the combined log format. Two \
            gigabytes a day, almost all of it one uncached endpoint.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Renaming a symbol across the repo", day: 27, tags: ["sed", "ripgrep"],
            lead: """
            No IDE refactor available on this machine, and the name appears in comments and \
            documentation as well as code, so a compiler-aware rename would have missed half of it.
            """,
            language: "sh",
            command: """
            rg -l 'candidateLimit' Sources | xargs sed -i '' 's/candidateLimit/candidatePerArm/g'
            """,
            trailer: """
            The empty `''` after `-i` is BSD sed's mandatory backup suffix — GNU sed does not want \
            it, which is why this line is wrong on Linux. Commit first, then run it, then diff.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Clearing out stale build folders", day: 91, tags: ["find"],
            lead: """
            Twenty checkouts on this disk, each with a build directory of a gigabyte or so, most of \
            them untouched since spring.
            """,
            language: "sh",
            command: """
            find . -type d -name .build -mtime +30 -print0 | xargs -0 rm -rf
            """,
            trailer: """
            The null separator is what makes this safe with paths that contain spaces. Run it once \
            with `-print` alone before adding the delete.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Which errors happen most", day: 54, tags: ["logs"],
            lead: """
            A day of logs and no aggregation anywhere. Cutting the message out of each line and \
            counting the duplicates gives the ranking in a second and a half.
            """,
            language: "sh",
            command: """
            grep -F 'ERROR' app.log | cut -d'|' -f4 | sort | uniq -c | sort -rn | head -20
            """,
            trailer: """
            `uniq -c` only collapses *adjacent* duplicates, which is why the first sort is not \
            optional. One message was 80% of the total and had been ignored for weeks.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "A script that cleans up after itself", day: 118, tags: ["bash"],
            lead: """
            The release script left half a gigabyte of scratch directories behind every time it \
            failed, which was often, because it also carried on happily after a failed step.
            """,
            language: "bash",
            command: """
            set -euo pipefail
            tmp="$(mktemp -d)"
            trap 'rm -rf "$tmp"' EXIT
            """,
            trailer: """
            The trap fires on a normal exit, an error and a Ctrl-C alike. `set -euo pipefail` is \
            the other half: without it a failing step in the middle of a pipeline is invisible.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Why tail into grep prints nothing", day: 102, tags: ["logs"],
            lead: """
            Following a log through a filter and seeing absolutely nothing for minutes, then \
            hundreds of lines at once. It is not the log and it is not the filter — it is that \
            grep buffers its output when it is writing to a pipe rather than a terminal.
            """,
            language: "sh",
            command: """
            tail -F /var/log/app/api.log | grep --line-buffered -E 'WARN|ERROR'
            """,
            trailer: """
            `-F` rather than `-f` so it survives log rotation. The same buffering trap applies to \
            `sed -u` and `awk` with `fflush()`.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "Catching a flaky test", day: 127, tags: ["bash", "testing"],
            lead: """
            One suite fails perhaps one run in thirty and only on a loaded machine, which makes it \
            impossible to study — by the time you notice, the output has scrolled away.
            """,
            language: "sh",
            command: """
            until ! swift test --filter ChurnTests; do :; done
            """,
            trailer: """
            Loops while the command keeps succeeding and stops the moment it fails, leaving the \
            failing output on screen. Took eleven minutes and forty-one runs to reproduce.
            """
        ),
    ]

    // MARK: - ssh, rsync, scp

    static let remote: [Golden] = [
        Golden(
            folder: "Infra/ssh", title: "Deploying the built site", day: 22, tags: ["rsync", "deploy"],
            lead: """
            The static bundle goes to the edge box directly while the pipeline is still being \
            rebuilt. Only changed files cross the wire, and anything on the far side that is no \
            longer in the build is removed.
            """,
            language: "sh",
            command: """
            rsync -avz --delete --exclude '.build' ./dist/ deploy@edge-01.internal.example:/srv/filaway/
            """,
            trailer: """
            The trailing slash on the source is load-bearing: without it rsync creates a `dist` \
            directory inside the destination instead of copying its contents. `--delete` with a \
            wrong path is how you erase a server, so it always runs with `-n` first.
            """
        ),
        Golden(
            folder: "Infra/ssh", title: "Tunnelling to the primary database", day: 48, tags: ["ssh", "postgres"],
            lead: """
            The database only accepts connections from inside the VPC and the only way in is the \
            bastion. Rather than run a client on the jump host, the port comes to me.
            """,
            language: "sh",
            command: """
            ssh -N -L 55434:db-primary.internal:5432 -J jump@bastion.internal.example deploy@edge-01.internal.example
            """,
            trailer: """
            `-N` means "no remote command, just the forward". `-J` does the two-hop dance that \
            used to need a ProxyCommand. Point the client at localhost:55434 and it looks local.
            """
        ),
        Golden(
            folder: "Infra/ssh", title: "Bringing a log back for reading", day: 81, tags: ["scp"],
            lead: """
            Grepping a 2 GB log over an ssh session on hotel wifi was hopeless, so the file came \
            down and the analysis happened locally.
            """,
            language: "sh",
            command: """
            scp deploy@edge-01.internal.example:/var/log/filaway/api-2026-07-11.log ~/Downloads/
            """,
            trailer: """
            For anything much bigger than this, rsync resumes and scp does not, which matters on a \
            connection that drops.
            """
        ),
        Golden(
            folder: "Infra/ssh", title: "Stop asking for the passphrase", day: 110, tags: ["ssh", "macos"],
            lead: """
            Every new terminal wanted the key passphrase again, which after a reboot is thirty \
            times a day. On macOS the agent can hand it to the Keychain and stop asking.
            """,
            language: "sh",
            command: """
            ssh-add --apple-use-keychain ~/.ssh/id_ed25519
            """,
            trailer: """
            Add `UseKeychain yes` and `AddKeysToAgent yes` under `Host *` in `~/.ssh/config` to \
            make it survive a reboot. The old spelling was `-K`, which still works but is deprecated.
            """
        ),
        Golden(
            folder: "Infra/ssh", title: "Sessions that stop dropping", day: 134, tags: ["ssh"],
            lead: """
            Every idle session died after a few minutes behind the office NAT, usually in the \
            middle of a long-running command. Keeping a trickle of traffic on the connection stops \
            the NAT deciding it is finished with it.
            """,
            language: "conf",
            command: """
            Host *.internal.example
              ServerAliveInterval 30
              ServerAliveCountMax 6
            """,
            trailer: """
            Client-side, so it works regardless of what the server allows. Six missed probes at \
            thirty seconds means a genuinely dead link is still noticed within three minutes.
            """
        ),
    ]

    // MARK: - package managers and runtimes

    static let packages: [Golden] = [
        Golden(
            folder: "Snippets/toolchain", title: "Pinning the postgres formula", day: 58, tags: ["brew"],
            lead: """
            An unrelated `brew upgrade` moved the local database a major version and every \
            checkout's data directory stopped being readable. It is pinned now.
            """,
            language: "sh",
            command: """
            brew reinstall postgresql@16 && brew pin postgresql@16
            """,
            trailer: """
            A pinned formula is skipped by upgrade and says so. Unpin deliberately when the \
            production version moves, not by accident on a Tuesday morning.
            """
        ),
        Golden(
            folder: "Snippets/toolchain", title: "Restarting the local database", day: 97, tags: ["brew", "postgres"],
            lead: """
            After changing `max_connections` the setting did not take, because the service had \
            been running since the last reboot and never re-read its configuration file.
            """,
            language: "sh",
            command: """
            brew services restart postgresql@16 && brew services list
            """,
            trailer: """
            The listing at the end is the useful half — it shows whether the service came back or \
            went straight to `error`, which a bare restart hides.
            """
        ),
        Golden(
            folder: "Snippets/toolchain", title: "Building one workspace package", day: 31, tags: ["pnpm", "monorepo"],
            lead: """
            A full workspace build is six minutes and I changed one leaf package. The filter \
            syntax builds that package and everything it depends on, and nothing else.
            """,
            language: "sh",
            command: """
            pnpm --filter @filaway/web... build
            """,
            trailer: """
            The trailing `...` means "and its dependencies"; a leading `...` means "and everything \
            that depends on it", which is the one to use before opening a pull request.
            """
        ),
        Golden(
            folder: "Snippets/toolchain", title: "What CI installs with", day: 75, tags: ["npm", "ci"],
            lead: """
            A build passed locally and failed in CI because the lockfile and the manifest \
            disagreed, and one of the two silently resolved the difference in its own favour.
            """,
            language: "sh",
            command: """
            npm ci --no-audit --fund=false
            """,
            trailer: """
            `ci` deletes `node_modules` and installs exactly the lockfile, failing if it does not \
            match the manifest. The two extra flags just stop it printing a wall of text.
            """
        ),
        Golden(
            folder: "Snippets/toolchain", title: "A fresh python environment", day: 39, tags: ["python"],
            lead: """
            The conversion scripts need their own interpreter state; installing them globally is \
            how the last machine ended up with three incompatible versions of one library.
            """,
            language: "sh",
            command: """
            python3 -m venv .venv && source .venv/bin/activate
            pip install -r requirements-dev.txt
            """,
            trailer: """
            `.venv` is gitignored and rebuilt in a minute, so it is never worth backing up. \
            `deactivate` when done, or just close the terminal.
            """
        ),
        Golden(
            folder: "Snippets/toolchain", title: "Serving a folder in the browser", day: 115, tags: ["python"],
            lead: """
            The generated documentation uses fetch for its search index, which the browser refuses \
            to do from a `file://` URL. It needs a real origin, and only for five minutes.
            """,
            language: "sh",
            command: """
            python3 -m http.server 8123 --bind 127.0.0.1 --directory ./out
            """,
            trailer: """
            Binding to loopback matters on a shared network — the default binds every interface \
            and quietly publishes whatever directory you are standing in.
            """
        ),
    ]

    // MARK: - media, certificates, data, system

    static let system: [Golden] = [
        Golden(
            folder: "Snippets/media", title: "Screen recording into a gif", day: 25, tags: ["ffmpeg"],
            lead: """
            The README wanted a six-second loop of the search panel. QuickTime records a 40 MB \
            .mov; the readme needs something under two megabytes that plays inline on GitHub.
            """,
            language: "sh",
            command: """
            ffmpeg -ss 00:00:04 -t 6 -i demo.mov -vf 'fps=12,scale=720:-1:flags=lanczos' -loop 0 demo.gif
            """,
            trailer: """
            Twelve frames a second is the point where a UI recording still reads as motion; the \
            `-1` keeps the aspect ratio. Put `-ss` before `-i` so the seek is fast.
            """
        ),
        Golden(
            folder: "Snippets/media", title: "Shrinking a video for chat", day: 93, tags: ["ffmpeg"],
            lead: """
            Screen captures come off this machine at about 8 MB a second, and the chat client \
            rejects anything over 25 MB, so everything worth sharing has to be re-encoded first.
            """,
            language: "sh",
            command: """
            ffmpeg -i raw.mov -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 96k small.mp4
            """,
            trailer: """
            CRF 28 with the slow preset is the sweet spot for screen content — text stays legible \
            and a two-minute capture lands around 12 MB. Lower CRF is bigger and better.
            """
        ),
        Golden(
            folder: "Infra/certs", title: "When does the certificate expire", day: 3, tags: ["openssl", "tls"],
            lead: """
            The monitoring alert for certificate expiry has been broken since June, so before the \
            release I checked the staging endpoint by hand. The subject line matters as much as \
            the dates — the wrong certificate for the right host is the failure mode nobody looks for.
            """,
            language: "sh",
            command: """
            openssl s_client -connect api.internal.example:443 -servername api.internal.example </dev/null 2>/dev/null | openssl x509 -noout -dates -subject
            """,
            trailer: """
            `-servername` sends SNI; without it a shared front end hands back its default \
            certificate and the answer is meaningless. Nineteen days left, renewal is automated.
            """
        ),
        Golden(
            folder: "Infra/certs", title: "A certificate for local https", day: 68, tags: ["openssl", "tls"],
            lead: """
            The service worker will not register over plain http, so the development server needs \
            a certificate even though nothing about it is trusted by anyone.
            """,
            language: "sh",
            command: """
            openssl req -x509 -newkey rsa:2048 -nodes -keyout local.key -out local.crt -days 365 -subj '/CN=localhost'
            """,
            trailer: """
            `-nodes` leaves the key unencrypted so the server can start unattended. Add it to the \
            login keychain and mark it trusted, or every request is an interstitial.
            """
        ),
        Golden(
            folder: "Snippets/data", title: "Exporting a table to csv", day: 45, tags: ["sqlite"],
            lead: """
            Wanted the note table in a spreadsheet to eyeball the modification dates against what \
            the sidebar was showing, with a header row so the columns mean something.
            """,
            language: "sh",
            command: """
            sqlite3 -header -csv filaway.sqlite "select id, relpath, mtime from notes order by mtime desc;" > notes.csv
            """,
            trailer: """
            The flags have to come before the filename. `mtime` is seconds since the epoch, so the \
            spreadsheet needs a formula to turn it into a date.
            """
        ),
        Golden(
            folder: "Snippets/data", title: "Is the database file healthy", day: 84, tags: ["sqlite"],
            lead: """
            After a hard power loss mid-write, before trusting the derived index again. Both checks \
            are cheap at this size and the file is disposable anyway.
            """,
            language: "sh",
            command: """
            sqlite3 filaway.sqlite 'pragma integrity_check; pragma foreign_key_check;'
            """,
            trailer: """
            The first walks the b-trees and prints `ok`; the second is the one that catches a \
            chunk row pointing at a note that no longer exists. Both came back clean.
            """
        ),
        Golden(
            folder: "Snippets/system", title: "Registering a login agent", day: 71, tags: ["launchctl", "macos"],
            lead: """
            The nightly reindex should start with the session and not need anyone to remember it. \
            `launchctl load` is deprecated and silently does nothing on recent systems.
            """,
            language: "sh",
            command: """
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tejaspanse.filaway.indexer.plist
            launchctl print gui/$(id -u)/com.tejaspanse.filaway.indexer
            """,
            trailer: """
            `print` is how you find out why it is not running — the exit status and the last spawn \
            time are both in there. Use `bootout` to remove it.
            """
        ),
        Golden(
            folder: "Snippets/system", title: "A long build in a detachable session", day: 122, tags: ["tmux"],
            lead: """
            A release build outlives the ssh connection and I want to close the laptop halfway \
            through, so it runs somewhere the terminal is not the thing keeping it alive.
            """,
            language: "sh",
            command: """
            tmux new-session -d -s build 'make release 2>&1 | tee build.log'
            tmux attach -t build
            """,
            trailer: """
            `-d` starts it detached so the first command returns immediately; `tee` means the log \
            survives even if the pane is closed. Ctrl-b d to detach again.
            """
        ),
    ]

    // MARK: - debugging sessions (the command is buried in prose)

    static let debugging: [Golden] = [
        Golden(
            folder: "Debugging/network", title: "Auth API 401 session", day: 2, tags: ["auth", "curl"],
            lead: """
            Half a day on this. Every call to the documents endpoint came back 401 with an empty \
            body, which the gateway does for both "no token" and "expired token" — the two cases \
            that need completely different fixes. The token in my environment had been minted on \
            Monday and the lifetime is an hour, so it had been dead for three days and I had been \
            reading the request headers for signs of a typo. Minting a fresh one takes one call \
            against the client-credentials grant, and the response carries the expiry so a script \
            can decide when to do it again.
            """,
            language: "sh",
            command: """
            curl -sS -X POST -u "$CLIENT_ID:$CLIENT_SECRET" -d 'grant_type=client_credentials' https://auth.internal.example/oauth2/token
            """,
            trailer: """
            The credentials go in the Basic header via `-u`, not in the body, which is what the \
            provider's own documentation gets wrong. Filed a ticket asking for a distinct status \
            or an error body on expiry; without one this will cost somebody else the same day.
            """
        ),
        Golden(
            folder: "Debugging/database", title: "Chasing a slow query", day: 50, tags: ["postgres", "performance"],
            lead: """
            The recents list took 900 ms on staging and 4 ms locally, and the only difference was \
            row count. Reading the plan the planner actually chose — with real timings and the \
            buffer counts, not the estimates — showed a sequential scan over the whole table \
            because the index on the modification column had never been created there.
            """,
            language: "sh",
            command: """
            psql "$DATABASE_URL" -X -c "explain (analyze, buffers) select id from notes where mtime > now() - interval '7 days';"
            """,
            trailer: """
            `analyze` runs the query for real, so never do this to a statement that writes. \
            `buffers` is what tells you whether the pages came from cache or from disk. After the \
            index: 900 ms to 3 ms, and the buffer count fell by four orders of magnitude.
            """
        ),
        Golden(
            folder: "Debugging/build", title: "The leak in the index build", day: 76, tags: ["memory", "swift"],
            lead: """
            Resident memory climbed steadily through a 5,000-note index build and never came back \
            down, which for a batch job that runs at launch is the difference between a fine \
            experience and a machine that starts swapping. Instruments needs Xcode, which this \
            machine does not have, but the command-line tool reports at exit and that was enough.
            """,
            language: "sh",
            command: """
            leaks --atExit -- .build/debug/filaway-bench index --notes 200
            """,
            trailer: """
            It was not a leak: it was the vector matrix growing by doubling and never being sized \
            down. The tool says "0 leaks for 0 total leaked bytes" and the footprint still grows, \
            which is exactly the distinction between a leak and unbounded retention.
            """
        ),
        Golden(
            folder: "Debugging/network", title: "Capturing the websocket handshake", day: 113, tags: ["tcpdump"],
            lead: """
            The client reconnected in a loop and neither side logged a reason. With no useful log \
            on either end, the only remaining source of truth is what actually went over the wire, \
            captured to a file so it can be opened somewhere with a real protocol decoder.
            """,
            language: "sh",
            command: """
            sudo tcpdump -i any -s 0 -w ws.pcap 'tcp port 8443'
            """,
            trailer: """
            `-s 0` captures whole packets rather than the first 96 bytes, `-w` writes the raw \
            capture instead of printing a summary. The upgrade request was being answered with a \
            301 by an intermediate proxy nobody knew was in the path.
            """
        ),
    ]

    // MARK: - meetings (an action item with a command in it)

    static let meetings: [Golden] = [
        Golden(
            folder: "Meetings/2026-08", title: "Platform sync", day: 11, tags: ["meeting", "kubernetes"],
            lead: """
            Platform are moving staging to the new cluster in Ireland on the first of next month. \
            The old context keeps working until then and is then deleted, so everyone's kubeconfig \
            needs the new one added and selected. Priya shared the two lines to run.
            """,
            language: "sh",
            command: """
            kubectl config use-context staging-eu-west-1
            kubectl config get-contexts
            """,
            trailer: """
            Other items: the log retention drops to seven days, the shared postgres gets a read \
            replica, and the on-call rotation moves to two-week blocks from September.
            """
        ),
        Golden(
            folder: "Meetings/2026-04", title: "Onboarding walkthrough", day: 124, tags: ["meeting", "setup"],
            lead: """
            Ran the new starter through a machine setup. Everything after the toolchain is one \
            command, which is the point of the bootstrap target — the environment file is decrypted \
            by direnv and the make target resolves dependencies and checks the optional tools.
            """,
            language: "sh",
            command: """
            git clone git@github.com:acme/filaway.git && cd filaway && direnv allow && make setup
            """,
            trailer: """
            Two things to fix in the guide: the ssh key has to be on the account before the clone, \
            and `direnv allow` fails with a confusing message if the hook is not in the shell rc.
            """
        ),
    ]

    // MARK: - odds and ends

    static let odds: [Golden] = [
        Golden(
            folder: "Snippets/data", title: "Tidying json on the clipboard", day: 136, tags: ["jq", "macos"],
            lead: """
            Someone pastes a single-line blob into chat and the only question is what shape it is. \
            Round-tripping it through the clipboard keeps it out of a file I would then forget to \
            delete.
            """,
            language: "sh",
            command: """
            pbpaste | jq . | pbcopy
            """,
            trailer: """
            `jq .` alone re-indents and sorts nothing; add `-S` when diffing two payloads, because \
            key order is otherwise whatever the server felt like.
            """
        ),
        Golden(
            folder: "Snippets/system", title: "Opening a downloaded binary", day: 143, tags: ["macos", "gatekeeper"],
            lead: """
            A helper tool downloaded from a release page refused to run — "cannot be opened because \
            the developer cannot be verified" — because the download put a quarantine attribute on \
            it that Gatekeeper checks before anything else.
            """,
            language: "sh",
            command: """
            xattr -d com.apple.quarantine ./tool
            """,
            trailer: """
            `xattr -l` first, to see what is actually attached. Doing this is deciding to trust the \
            binary yourself, so it is a per-file decision and never a blanket one.
            """
        ),
        Golden(
            folder: "Commands/shell", title: "A key as one long line", day: 131, tags: ["bash", "secrets"],
            lead: """
            The deployment target wants the signing key as a single-line environment variable, and \
            a stray newline in the middle produces an error message that says nothing useful.
            """,
            language: "sh",
            command: """
            base64 -i secret.pem | tr -d '\\n' | pbcopy
            """,
            trailer: """
            macOS `base64` wraps at 76 columns unless you strip them; GNU coreutils wants `-w 0` \
            instead. Never let this land in shell history — it is on the clipboard, then gone.
            """
        ),
        Golden(
            folder: "Debugging/build", title: "What is this binary linking", day: 89, tags: ["macos", "linking"],
            lead: """
            The app launched on my machine and died instantly on a clean one, which is nearly \
            always a link against something only a development install provides.
            """,
            language: "sh",
            command: """
            otool -L build/Filaway.app/Contents/MacOS/Filaway
            """,
            trailer: """
            Everything should resolve under `/usr/lib`, `/System` or `@rpath` inside the bundle. \
            An absolute path into a Homebrew prefix is the bug.
            """
        ),
    ]

    static let golden: [Golden] =
        curl + git + docker + kubernetes + shell + remote + packages + system + debugging
            + meetings + odds
}
