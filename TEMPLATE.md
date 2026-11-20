# TEMPLATE: GitHub Actions Self-Hosted Runner 2.338 (Ubuntu 24.04)

Composer spec. `template.json` is the machine-readable copy.

## Service

| Field | Value |
|---|---|
| Name | GitHub Runner |
| Source | repo `baranberkay96/github-runner-railway`, root `/services/runner` |
| Base | `ubuntu:noble-20261110.1@sha256:882e1e56…` |
| Runner | actions/runner 2.338.2 release tarball, SHA-256 pinned (checked 2026-11-20); gh 2.105.0 |
| Public domain | none (outbound connection to GitHub only) |
| Healthcheck | none (no HTTP port); the process never exits on configuration errors |
| Restart | ALWAYS |
| Volume | `/data` (registration files, generated runner name) |

Required inputs: `GITHUB_URL` (prefilled with a `{owner}/{repo}` pattern the script rejects until replaced) and `RUNNER_TOKEN` (registration token or PAT). Optional: `RUNNER_LABELS` (railway), `RUNNER_NAME`, `RUNNER_GROUP`, `RUNNER_EPHEMERAL` (false), `RUNNER_SUDO` (true), `RUNNER_DISABLE_UPDATE` (false), `APT_PACKAGES`, `TZ`, `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` (60).

## Improvements over market templates

- Pinned runner release with SHA-256 instead of `myoung34/github-runner:latest` (a 1.5 GB image built around Docker, which cannot run on Railway).
- Registration kept on a volume: restarts and redeploys need no new token; registration tokens (1 h) become usable.
- PAT mode: requests registration tokens itself, re-registers after the runner was removed in GitHub, supports ephemeral runners in a loop.
- Missing/invalid URL or token, or GitHub errors (401/403/404) never crash-loop the deploy: clear log message and backoff (STANDARD 8.29).
- Token removed from the jobs' environment; `--token` redacted from logs.
- Graceful SIGTERM (runner cancels the job and reports it), 60 s draining.
- Clear statement that Docker-based jobs cannot run.

## Resources

| Service | Idle RAM | Typical RAM | CPU |
|---|---|---|---|
| GitHub Runner | ≈3 MB unconfigured (measured); ~0.1–0.2 GB registered (estimate) | 0.5–4 GB during builds | near 0 idle; builds use what they need |

Estimated cost: about $1–3/month idle, plus the compute your jobs use. Minimum plan: Trial for light jobs; Hobby for real builds.

## Verification checklist

- Default deploy (placeholder URL, placeholder token): service SUCCESS, log says what to set, no restarts.
- Invalid PAT-shaped token with a real public repo URL: log shows GitHub 401 message and backoff, service stays up.
- With a real token (needs the user's own GitHub token; not done by the agent): runner registers, a `runs-on: [self-hosted, railway]` job runs, redeploy reuses the registration.

## Open questions

- A full registration and job run need a GitHub token from the user; only the no-token and bad-token paths were tested on Railway.
