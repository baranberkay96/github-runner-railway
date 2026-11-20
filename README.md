# Deploy and Host GitHub Actions Self-Hosted Runner with Railway

A GitHub Actions self-hosted runner on Railway: it registers with your repository or organization, picks up jobs whose `runs-on` asks for it, and keeps its registration on a volume so restarts and redeploys need no new token. Ubuntu 24.04 with git, compilers, Python, jq and the GitHub CLI. Docker is not available.

## About Hosting GitHub Actions Self-Hosted Runner

A self-hosted runner is GitHub's open-source `actions/runner` program. It opens an outbound HTTPS connection to GitHub and runs the jobs GitHub assigns to it, so it needs no public port. This community template builds runner 2.338.2 from the release tarball (SHA-256 checked) on a pinned Ubuntu 24.04 image. A start script registers the runner with a registration token or a personal access token, stores the registration on a Railway volume, restarts the runner when it stops, registers again when GitHub has deleted it (with a PAT), and stays up with a clear log message instead of crash-looping when the URL or token is missing or wrong.

## Common Use Cases

- Run CI jobs (tests, builds, linters) on Railway compute instead of GitHub-hosted minutes
- Deploy to services in your Railway project over the private network from a workflow
- Run scheduled workflows that need more RAM or a longer runtime than hosted runners give
- Keep build caches and tools warm between jobs on one persistent machine

## Dependencies for GitHub Actions Self-Hosted Runner Hosting

- One service built from a Dockerfile on `ubuntu:noble` (no database, no public domain)
- A Railway volume at `/data` for the runner registration
- A GitHub repository or organization where you may add self-hosted runners

### Deployment Dependencies

- [actions/runner releases](https://github.com/actions/runner/releases)
- [About self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
- [Registration token API](https://docs.github.com/en/rest/actions/self-hosted-runners)
- [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
- [Railway Fair Use Policy](https://railway.com/legal/fair-use)

### Implementation Details

| Service | What runs inside | Volume | Port |
|---|---|---|---|
| GitHub Runner | `actions/runner` 2.338.2 as user `runner`, started and supervised by `railway-runner` | `/data` (registration, runner name) | none (outbound only) |

**Plan:** RAM_PLACEHOLDER

**Setup**

1. Set `GITHUB_URL` to `https://github.com/{owner}/{repo}` for a repository runner, or `https://github.com/{org}` for an organization runner.
2. Set `RUNNER_TOKEN` to one of:
   - a **registration token**: repository (or organization) Settings, Actions, Runners, New self-hosted runner, the value after `--token`. It is valid for one hour, which is enough for the first registration; afterwards the volume keeps the runner registered.
   - a **personal access token**: fine-grained with "Administration: read and write" on the repository, or "Self-hosted runners: read and write" on the organization (classic: `repo` or `admin:org`). With a PAT the runner can register again by itself at any time, which `RUNNER_EPHEMERAL=true` needs.
3. Deploy. The log shows `Runner registered` and `Listening for Jobs`; the runner appears under Settings, Actions, Runners.
4. In a workflow, use `runs-on: [self-hosted, railway]` (or your `RUNNER_LABELS`).

If the URL or token is missing or GitHub refuses it, the service keeps running, logs the reason (for example "token is wrong, expired or revoked" or a missing permission) and retries with a growing delay. Fix the variable and redeploy.

**No Docker: what does not work**

Railway runs no nested containers, so there is no Docker daemon. Jobs with `container:`, `services:`, Docker container actions (`uses: docker://...` or actions with a `Dockerfile`) and `docker build` fail on this runner. JavaScript and composite actions (checkout, setup-node, setup-python, cache, upload-artifact and most others) work. Build container images with a hosted runner or with Railway's own builds instead.

**Persistence and updates**

`/data` keeps the registration, so redeploys reuse it without a token. Removing the runner in GitHub's settings makes the service forget it; with a PAT it registers again by itself. The work folder is on the container disk and is empty after each redeploy. The runner updates itself when GitHub requires a newer version; to move the image to a newer release, change `RUNNER_VERSION` and `RUNNER_SHA256` in `services/runner/Dockerfile`. `APT_PACKAGES` installs extra Ubuntu packages at every start.

**Security**

- Never attach a self-hosted runner to a public repository: anyone who opens a pull request could run code on it (GitHub's own advice).
- Jobs run as user `runner` with passwordless sudo by default (`RUNNER_SUDO=false` removes it). The token is removed from the jobs' environment, but a job with sudo can read everything in the container, including the token. Use a fine-grained PAT limited to one repository, or a registration token.
- Jobs reach your project's private network (`*.railway.internal`). Only run workflows you trust.
- To delete the runner, remove the Railway service and then the offline runner under Settings, Actions, Runners.

**Scaling**

One service is one runner and runs one job at a time. The volume keeps it to one replica; for parallel jobs, deploy the template again (each deploy registers its own runner) and give them the same label.

**Fair use**

CI jobs are normal compute on Railway. Cryptocurrency mining, proxies or VPN exits, abusive bots and reselling compute are not allowed by Railway's Fair Use Policy, also not inside workflow jobs.

### Why Deploy GitHub Actions Self-Hosted Runner on Railway?

Railway gives the runner a machine that is always on, bills only the RAM and CPU your jobs use, and puts it next to your databases and services on the private network. Set two variables and the runner shows up in GitHub. This is a community template, not affiliated with GitHub or Railway.
