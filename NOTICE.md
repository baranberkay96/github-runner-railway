# NOTICE: GitHub Actions Self-Hosted Runner template

This is a community template. It is not made, endorsed or supported by GitHub or Railway. GitHub and GitHub Actions are trademarks of GitHub, Inc.

## Components

| Component | Source | License | How it is used |
|---|---|---|---|
| GitHub Actions Runner 2.338.2 (`actions-runner-linux-x64-2.338.2.tar.gz`, SHA-256 `baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40`) | https://github.com/actions/runner | MIT (Copyright (c) GitHub) | Downloaded at build time into `/home/runner/actions-runner`, unmodified; its `bin/installdependencies.sh` installs the system libraries it needs |
| GitHub CLI 2.105.0 (`gh_2.105.0_linux_amd64.tar.gz`, SHA-256 `79e7ab5db738c48777b696e374f8b428f0647debfb424f44d2f426370407fe2f`) | https://github.com/cli/cli | MIT | Binary installed to `/usr/local/bin/gh` |
| Ubuntu 24.04 (`ubuntu:noble-20261110.1@sha256:882e1e56091c9ffbc70c026ff5935fe85d3c91ad155917865ba2ffa23ede1560`) and its packages (git, build-essential, Python 3, jq, sudo, tini and others) | https://hub.docker.com/_/ubuntu, https://packages.ubuntu.com/noble/ | Each package's own license (`/usr/share/doc/*/copyright`) | Base image and apt packages |

The runner's own license and third-party notices ship inside the runner directory of the image.

## Files written for this template

`services/runner/Dockerfile`, `services/runner/railway-runner.sh` and the documentation were written for this template and are offered under the MIT License. No file from the marketplace templates or from `myoung34/docker-github-actions-runner` (the image most of them use) was copied; that project was read for the list of options users expect (labels, ephemeral mode, organization scope, runner groups).

## Upstream files checked

- actions/runner v2.338.2 release notes (download URL and SHA-256), `src/Misc/layoutroot/run.sh` (`RUNNER_MANUALLY_TRAP_SIG`, restart and update exit codes), `src/Runner.Common/Constants.cs` (listener return codes), `src/Misc/layoutbin/installdependencies.sh`.
- GitHub REST API: `POST /repos/{owner}/{repo}/actions/runners/registration-token` and `POST /orgs/{org}/actions/runners/registration-token`.
- cli/cli v2.105.0 `gh_2.105.0_checksums.txt`.

## Market templates

The three GitHub runner templates on the Railway marketplace (two use `myoung34/github-runner:latest`, one builds its own image) were reviewed for features only. No files or text were copied.

## Railway Fair Use

CI jobs are normal compute. Cryptocurrency mining, proxies, VPN exits, abusive bots and reselling compute are not allowed, also inside jobs.
