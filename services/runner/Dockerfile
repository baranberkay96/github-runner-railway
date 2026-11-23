# syntax=docker/dockerfile:1
#
# GitHub Actions self-hosted runner 2.338.2 on Ubuntu 24.04, for Railway.
#
# Base: Docker Hub library/ubuntu, dated tag noble-20261110.1, pinned by
# its multi-arch index digest. The runner and the GitHub CLI are release
# tarballs from GitHub, checked against the SHA-256 their releases publish
# (they stay downloadable; STANDARD 8.27). To upgrade the runner, take the
# version and the "linux-x64" SHA-256 from
# https://github.com/actions/runner/releases. Between upgrades the runner
# updates itself when GitHub asks it to (unless RUNNER_DISABLE_UPDATE=true).
FROM ubuntu:noble-20261110.1@sha256:882e1e56091c9ffbc70c026ff5935fe85d3c91ad155917865ba2ffa23ede1560

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
ARG GH_VERSION=2.105.0
ARG GH_SHA256=79e7ab5db738c48777b696e374f8b428f0647debfb424f44d2f426370407fe2f

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Common CI tools, similar in spirit to GitHub's hosted Ubuntu image (much
# smaller): git, compilers, Python, archive tools, jq, sudo. No Docker.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl file git git-lfs gnupg jq less \
      lsb-release make openssh-client python3 python3-pip python3-venv \
      rsync sudo tini tzdata unzip wget xz-utils zip zstd \
 && rm -rf /var/lib/apt/lists/*

# Unprivileged user the runner and all jobs run as (uid 1001, like GitHub's
# hosted runners), with passwordless sudo that RUNNER_SUDO=false removes.
RUN useradd --create-home --uid 1001 --shell /bin/bash runner \
 && printf 'runner ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# Runner release tarball and its own dependency script (libicu, krb5, ...).
RUN install -d -o runner -g runner /home/runner/actions-runner \
 && curl -fsSL --retry 5 --retry-all-errors -o /tmp/runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/runner.tar.gz -C /home/runner/actions-runner \
 && rm -f /tmp/runner.tar.gz \
 && /home/runner/actions-runner/bin/installdependencies.sh \
 && printf '%s\n' "${RUNNER_VERSION}" > /home/runner/actions-runner/.version \
 && chown -R runner:runner /home/runner \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI, used by many workflows.
RUN curl -fsSL --retry 5 --retry-all-errors -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gh.tar.gz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64" \
 && gh --version | head -n 1

COPY --chmod=0755 railway-runner.sh /usr/local/bin/railway-runner
COPY --chmod=0755 railway-healthz.py /usr/local/bin/railway-healthz
RUN bash -n /usr/local/bin/railway-runner \
 && python3 -m py_compile /usr/local/bin/railway-healthz

WORKDIR /home/runner

# The script starts as root (volume ownership, optional packages), then
# runs the runner as "runner". tini forwards SIGTERM and reaps job
# processes; it is a subreaper (-s) because Railway's own init is PID 1.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/usr/local/bin/railway-runner"]
