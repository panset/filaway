import Foundation

/// A tiny developer-notes corpus with known answers, used by the M1-08 spike to
/// get a *directional* quality signal for each embedder.
///
/// This is deliberately small and hand-written: 40 notes of the kind Filaway is
/// for (a command plus the sentence of context you would actually type around
/// it) and 20 queries phrased the way you would ask months later — mostly
/// **without** the words in the note, which is the entire reason to have a
/// semantic index at all.
///
/// It is not the M3-07 benchmark. M3-07 needs a generated 5k/20k corpus, real
/// chunking, hybrid ranking and a ≥90% top-1 gate; treat these numbers as
/// "does this model understand developer English", nothing more.
public enum RetrievalSpikeCorpus {
    public struct Note: Sendable, Identifiable, Equatable {
        public let id: String
        public let title: String
        public let body: String
        /// What the index would actually embed: title then body.
        public var text: String { "\(title)\n\(body)" }
    }

    public struct Query: Sendable, Equatable {
        public let text: String
        /// `id` of the note that answers it.
        public let expected: String
    }

    public static let notes: [Note] = [
        .init(id: "curl-post-json", title: "POST JSON from the terminal",
              body: "Send a JSON body to an API and see the response headers:\n" +
                  "curl -sS -X POST -H 'Content-Type: application/json' -d '{\"name\":\"widget\"}' https://api.example.com/items"),
        .init(id: "curl-follow-redirects", title: "Follow redirects with curl",
              body: "By default curl stops at a 301. -L follows the chain, -i shows each response header:\ncurl -iL https://example.com/short"),
        .init(id: "curl-download-file", title: "Save a download to disk",
              body: "-O keeps the remote filename, -o renames it, -C - resumes a partial transfer:\ncurl -OL https://example.com/release.tar.gz"),
        .init(id: "curl-timing", title: "Measure how long a request takes",
              body: "Print connect, TLS handshake and total duration instead of the body:\n" +
                  "curl -o /dev/null -sS -w 'dns=%{time_namelookup} tls=%{time_appconnect} total=%{time_total}\\n' https://example.com"),
        .init(id: "curl-bearer-auth", title: "Call an API with a token",
              body: "Keep the secret out of shell history by reading it from the environment:\ncurl -H \"Authorization: Bearer $API_TOKEN\" https://api.example.com/me"),
        .init(id: "git-undo-last-commit", title: "Undo the last commit, keep the work",
              body: "Move the branch pointer back one commit; the changes stay staged in the index:\ngit reset --soft HEAD~1"),
        .init(id: "git-amend-message", title: "Rewrite the message of the newest commit",
              body: "Only safe before you push. Amend replaces the commit rather than adding one:\ngit commit --amend -m 'better wording'"),
        .init(id: "git-reflog-recover", title: "Get back a commit that seems gone",
              body: "Every position HEAD has ever had is listed for 90 days; check it out or reset onto it:\ngit reflog\ngit reset --hard HEAD@{3}"),
        .init(id: "git-cherry-pick", title: "Take one commit from another branch",
              body: "Apply a single commit onto the current branch, -x records where it came from:\ngit cherry-pick -x 4f2a1c9"),
        .init(id: "git-stash-untracked", title: "Park work in progress including new files",
              body: "Plain stash ignores untracked files; -u includes them, and pop puts everything back:\ngit stash push -u -m 'wip parser'\ngit stash pop"),
        .init(id: "git-bisect", title: "Find the commit that introduced a bug",
              body: "Binary search over history, automated with a script that exits non-zero on failure:\ngit bisect start HEAD v1.4.0\ngit bisect run ./test.sh"),
        .init(id: "git-delete-remote-branch", title: "Remove a branch from the server",
              body: "Deleting it locally leaves the copy on the remote; also prune stale tracking refs:\ngit push origin --delete feature/old\ngit fetch --prune"),
        .init(id: "git-rebase-squash", title: "Combine several commits into one",
              body: "Interactive rebase, then mark every commit after the first as squash or fixup:\ngit rebase -i HEAD~5"),
        .init(id: "git-blame-ignore-format", title: "Blame past a reformatting commit",
              body: "List the noise commits in a file so blame skips straight to the real author:\ngit blame --ignore-revs-file .git-blame-ignore-revs src/main.swift"),
        .init(id: "docker-image-prune", title: "Reclaim space from unused images",
              body: "Dangling layers pile up after every rebuild; -a also drops images no container uses:\ndocker image prune -a\ndocker system df"),
        .init(id: "docker-exec-shell", title: "Open a shell inside a running container",
              body: "-i -t attaches a terminal; use sh when the image has no bash:\ndocker exec -it api-1 /bin/bash"),
        .init(id: "docker-cp", title: "Move a file between host and container",
              body: "Works in both directions and while the container is stopped:\ndocker cp api-1:/var/log/app.log ./app.log"),
        .init(id: "docker-logs-follow", title: "Stream a container's output live",
              body: "-f keeps the stream open, --tail limits the backlog, -t adds timestamps:\ndocker logs -f --tail 100 -t api-1"),
        .init(id: "docker-build-no-cache", title: "Force a clean image build",
              body: "When a cached layer is stale, skip the cache and always re-pull the base image:\ndocker build --no-cache --pull -t myapp:dev ."),
        .init(id: "docker-compose-rebuild", title: "Recreate one service after a code change",
              body: "Rebuild a single service and restart only it, leaving the database up:\ndocker compose up -d --build api"),
        .init(id: "docker-port-mapping", title: "Expose a container port on the host",
              body: "Left of the colon is the host port, right is the container port:\ndocker run -d -p 8080:80 nginx"),
        .init(id: "kubectl-get-pods-all", title: "List every pod in the cluster",
              body: "Across all namespaces, widest output, sorted by how often they have restarted:\nkubectl get pods -A -o wide --sort-by=.status.containerStatuses[0].restartCount"),
        .init(id: "kubectl-logs-previous", title: "Read the logs of a container that died",
              body: "-p shows the previous instance, which is the only copy of why it crashed:\nkubectl logs -p checkout-7d9f -c server"),
        .init(id: "kubectl-port-forward", title: "Reach a cluster service from localhost",
              body: "Tunnels a local port to a pod or service through the API server:\nkubectl port-forward svc/postgres 5432:5432"),
        .init(id: "kubectl-describe-node", title: "See why a node is refusing work",
              body: "Conditions at the bottom show memory or disk pressure and taints:\nkubectl describe node ip-10-0-1-23\nkubectl top nodes"),
        .init(id: "kubectl-exec-shell", title: "Get a shell in a pod",
              body: "Same idea as docker exec, with the container named when there is more than one:\nkubectl exec -it checkout-7d9f -c server -- sh"),
        .init(id: "kubectl-rollout-restart", title: "Restart every pod of a deployment",
              body: "The clean way to make pods pick up a changed ConfigMap or Secret:\nkubectl rollout restart deployment/checkout\nkubectl rollout status deployment/checkout"),
        .init(id: "kubectl-decode-secret", title: "Read the value stored in a Secret",
              body: "Values are base64, not encrypted, so decoding is a pipe away:\nkubectl get secret db -o jsonpath='{.data.password}' | base64 -d"),
        .init(id: "ssh-local-forward", title: "Tunnel a remote database to a local port",
              body: "Forward localhost:5432 over the SSH connection; -N means no remote shell:\nssh -N -L 5432:db.internal:5432 bastion.example.com"),
        .init(id: "ssh-copy-id", title: "Stop typing a password on every login",
              body: "Install your public key in the server's authorized_keys:\nssh-copy-id -i ~/.ssh/id_ed25519.pub user@host"),
        .init(id: "ssh-config-alias", title: "Give a server a short name",
              body: "~/.ssh/config entries apply to ssh, scp and rsync alike:\nHost bastion\n  HostName 10.0.0.7\n  User deploy\n  IdentityFile ~/.ssh/id_ed25519"),
        .init(id: "scp-copy-file", title: "Copy a file to a remote machine",
              body: "-r for directories; the colon separates host from path:\nscp -r ./dist user@host:/srv/www/"),
        .init(id: "rsync-mirror", title: "Make a destination match a source exactly",
              body: "--delete removes files the source no longer has; -n shows what would happen first:\nrsync -avn --delete ./site/ user@host:/srv/www/"),
        .init(id: "find-large-files", title: "Track down what filled the disk",
              body: "Biggest directories first, then the individual offenders:\ndu -sh * | sort -rh | head -20\nfind . -type f -size +200M -exec ls -lh {} +"),
        .init(id: "lsof-port", title: "Find the process occupying a port",
              body: "Address already in use — this is who has it:\nlsof -nP -iTCP:8080 -sTCP:LISTEN\nkill -9 <pid>"),
        .init(id: "sed-inplace", title: "Change text in files without an editor",
              body: "BSD sed needs an argument to -i; '' means no backup:\nsed -i '' 's/staging/production/g' config/*.yml"),
        .init(id: "jq-filter", title: "Pull fields out of a JSON response",
              body: "Map over an array and build a smaller object, -r drops the quotes:\ncurl -sS https://api.example.com/items | jq -r '.items[] | {id, name} | @tsv'"),
        .init(id: "tar-extract", title: "Unpack and inspect an archive",
              body: "-t lists without extracting, -C chooses where it lands:\ntar -tzf bundle.tar.gz\ntar -xzf bundle.tar.gz -C /tmp/out"),
        .init(id: "openssl-cert-expiry", title: "Check when a certificate expires",
              body: "Ask the live endpoint rather than trusting the file on disk:\necho | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -dates"),
        .init(id: "macos-quarantine", title: "macOS says an app is damaged",
              body: "Gatekeeper's quarantine flag on an unsigned download; strip it and re-sign ad hoc:\nxattr -dr com.apple.quarantine /Applications/Thing.app\ncodesign -s - --force --deep /Applications/Thing.app"),
    ]

    public static let queries: [Query] = [
        .init(text: "how do I throw away my most recent commit but keep the changes", expected: "git-undo-last-commit"),
        .init(text: "recover work from a commit I deleted by accident", expected: "git-reflog-recover"),
        .init(text: "which program is holding on to port 8080", expected: "lsof-port"),
        .init(text: "get a shell inside a running container", expected: "docker-exec-shell"),
        .init(text: "see why a pod crashed before it restarted", expected: "kubectl-logs-previous"),
        .init(text: "reach a database on a remote machine over an encrypted connection", expected: "ssh-local-forward"),
        .init(text: "reclaim disk space taken up by old container images", expected: "docker-image-prune"),
        .init(text: "when does the TLS certificate for a website expire", expected: "openssl-cert-expiry"),
        .init(text: "send a JSON payload to an endpoint from the command line", expected: "curl-post-json"),
        .init(text: "keep two folders identical and drop files the source no longer has", expected: "rsync-mirror"),
        .init(text: "stop being asked for a password every time I log into the server", expected: "ssh-copy-id"),
        .init(text: "replace a word across several files without opening an editor", expected: "sed-inplace"),
        .init(text: "extract one field from an API response", expected: "jq-filter"),
        .init(text: "find out what is eating all my disk space", expected: "find-large-files"),
        .init(text: "watch application output as it happens in a container", expected: "docker-logs-follow"),
        .init(text: "open a service running in the cluster in my laptop browser", expected: "kubectl-port-forward"),
        .init(text: "make pods pick up a changed config map", expected: "kubectl-rollout-restart"),
        .init(text: "fix a typo in the message of the commit I just made", expected: "git-amend-message"),
        .init(text: "the app I downloaded says it is damaged and will not open", expected: "macos-quarantine"),
        .init(text: "how long did the http request actually take", expected: "curl-timing"),
    ]
}
