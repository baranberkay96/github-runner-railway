#!/usr/bin/env bash
# railway-runner: registers and runs a GitHub Actions self-hosted runner on Railway.
#
#  - GITHUB_URL is a repository (https://github.com/{owner}/{repo}) or an
#    organization (https://github.com/{org}); GitHub Enterprise Server hosts
#    work the same way.
#  - RUNNER_TOKEN is either a short-lived registration token (from the
#    repository's Settings > Actions > Runners > New self-hosted runner) or a
#    personal access token that may create registration tokens. With a PAT
#    the runner can re-register by itself at any time; a registration token
#    expires after one hour.
#  - The registration (.runner and credential files) is kept on the Railway
#    volume, so redeploys and restarts reuse it without any token.
#  - RUNNER_EPHEMERAL=true: one job per registration, then a fresh one
#    (needs a PAT, or a registration token that is still valid).
#  - Nothing ever fails the deploy: without a usable URL or token, or when
#    GitHub refuses the registration, the service stays up, says why in the
#    log every few minutes and retries with a growing delay.
set -Eeuo pipefail

readonly RUNNER_USER="runner"
readonly RUNNER_HOME="/home/runner"
readonly RUNNER_DIR="/home/runner/actions-runner"
readonly WORK_DIR="/home/runner/_work"
readonly STATE_DIR="/data/runner"
readonly STATE_FILES=(.runner .credentials .credentials_rsaparams)
readonly NAME_FILE="/data/runner-name"
readonly RUN_LOG="/tmp/railway-runner-run.log"
readonly PLACEHOLDER_HINT="https://github.com/{owner}/{repo}"
readonly MIN_RETRY_S=60
readonly MAX_RETRY_S=3600
readonly IDLE_REMINDER_S=900

RUN_PID=""
RETRY_S=$MIN_RETRY_S
STOPPING=0

log() { printf '[railway-runner] %s\n' "$*" >&2; }

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# Jobs never see the token: it is removed from the environment of
# everything started as the runner user.
as_runner() {
  setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups \
    env -u RUNNER_TOKEN -u GITHUB_TOKEN HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" "$@"
}

# Sleeps in short steps so SIGTERM is handled at once.
pause() {
  local end=$(( SECONDS + $1 ))
  while (( SECONDS < end && STOPPING == 0 )); do sleep 5; done
}

backoff() {
  log "Retrying in $(( RETRY_S / 60 )) min."
  pause "$RETRY_S"
  RETRY_S=$(( RETRY_S * 2 > MAX_RETRY_S ? MAX_RETRY_S : RETRY_S * 2 ))
}

# Stays up without doing anything until the service is redeployed with
# better variables; a crash loop would only fail the deploy.
idle_forever() {
  while (( STOPPING == 0 )); do
    log "$*"
    pause "$IDLE_REMINDER_S"
  done
  exit 0
}

# ---------------------------------------------------------------- inputs

parse_url() {
  local url="${GITHUB_URL:-}"
  url="${url%/}"
  url="${url%.git}"
  if [[ "$url" =~ ^https://([A-Za-z0-9.-]+(:[0-9]+)?)/([A-Za-z0-9]([A-Za-z0-9-]{0,38}))(/([A-Za-z0-9._-]{1,100}))?$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    OWNER="${BASH_REMATCH[3]}"
    REPO="${BASH_REMATCH[6]}"
    URL="$url"
    if [[ "$HOST" == "github.com" ]]; then
      API="https://api.github.com"
    else
      API="https://${HOST}/api/v3"
    fi
    if [[ -n "$REPO" ]]; then
      SCOPE="repository ${OWNER}/${REPO}"
      TOKEN_ENDPOINT="${API}/repos/${OWNER}/${REPO}/actions/runners/registration-token"
    else
      SCOPE="organization ${OWNER}"
      TOKEN_ENDPOINT="${API}/orgs/${OWNER}/actions/runners/registration-token"
    fi
    return 0
  fi
  return 1
}

token_kind() {
  local token="${RUNNER_TOKEN:-}"
  if [[ -z "$token" || "$token" == placeholder* || ${#token} -lt 20 || "$token" =~ [[:space:]] ]]; then
    printf 'none\n'
  elif [[ "$token" =~ ^(ghp_|github_pat_|gho_|ghu_|ghs_) ]]; then
    printf 'pat\n'
  else
    printf 'registration\n'
  fi
}

runner_name() {
  local name="${RUNNER_NAME:-}"
  if [[ -n "$name" && "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    printf '%s\n' "$name"
    return 0
  fi
  [[ -z "$name" ]] || log "WARNING: RUNNER_NAME may only use letters, digits and . _ - (1-64). Using a generated name."
  if [[ ! -s "$NAME_FILE" ]]; then
    printf 'railway-%s\n' "$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$NAME_FILE"
  fi
  cat "$NAME_FILE"
}

runner_labels() {
  local labels="${RUNNER_LABELS:-railway}"
  labels="${labels// /}"
  if [[ ! "$labels" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
    log "WARNING: RUNNER_LABELS must be comma-separated words (letters, digits, . _ -). Using 'railway'."
    labels="railway"
  fi
  printf '%s\n' "$labels"
}

# ---------------------------------------------------------------- state

prepare_dirs() {
  if command -v mountpoint > /dev/null 2>&1 && ! mountpoint -q /data; then
    log "WARNING: /data is not a mounted volume. The registration is lost on every redeploy."
  fi
  install -d -m 0700 -o "$RUNNER_USER" -g "$RUNNER_USER" "$STATE_DIR"
  install -d -m 0755 -o "$RUNNER_USER" -g "$RUNNER_USER" "$WORK_DIR"
}

restore_state() {
  local f
  for f in "${STATE_FILES[@]}"; do
    rm -f -- "${RUNNER_DIR}/${f}"
    if [[ -f "${STATE_DIR}/${f}" ]]; then
      install -m 0600 -o "$RUNNER_USER" -g "$RUNNER_USER" "${STATE_DIR}/${f}" "${RUNNER_DIR}/${f}"
    fi
  done
}

save_state() {
  local f
  for f in "${STATE_FILES[@]}"; do
    if [[ -f "${RUNNER_DIR}/${f}" ]]; then
      install -m 0600 -o "$RUNNER_USER" -g "$RUNNER_USER" "${RUNNER_DIR}/${f}" "${STATE_DIR}/${f}"
    fi
  done
}

forget_state() {
  local f
  for f in "${STATE_FILES[@]}"; do
    rm -f -- "${RUNNER_DIR}/${f}" "${STATE_DIR}/${f}"
  done
}

is_configured() { [[ -s "${RUNNER_DIR}/.runner" && -s "${RUNNER_DIR}/.credentials" ]]; }

configured_url() {
  sed -n 's/.*"gitHubUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${RUNNER_DIR}/.runner" 2> /dev/null | head -n 1
}

# ---------------------------------------------------------------- GitHub

# Prints a registration token, or explains the failure and returns 1.
registration_token() {
  local kind body status
  kind="$(token_kind)"
  if [[ "$kind" == registration ]]; then
    printf '%s\n' "$RUNNER_TOKEN"
    return 0
  fi
  body="$(mktemp)"
  status="$(curl -sS --retry 3 --retry-all-errors -o "$body" -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer ${RUNNER_TOKEN}" "$TOKEN_ENDPOINT" 2> /dev/null || printf '000')"
  if [[ "$status" == 201 ]]; then
    jq -r '.token // empty' "$body"
    rm -f "$body"
    return 0
  fi
  case "$status" in
    401) log "GitHub rejected RUNNER_TOKEN (401): the token is wrong, expired or revoked." ;;
    403) log "GitHub refused (403): the token may not manage self-hosted runners of the ${SCOPE}. Fine-grained PAT: 'Administration: read and write' on the repository, or 'Self-hosted runners: read and write' on the organization. Classic PAT: 'repo' or 'admin:org'." ;;
    404) log "GitHub answered 404 for the ${SCOPE}: wrong GITHUB_URL, or the token cannot see it." ;;
    000) log "Could not reach ${API} (network error)." ;;
    *) log "GitHub answered HTTP ${status} when asked for a registration token: $(jq -r '.message // empty' "$body" 2> /dev/null | head -c 200)" ;;
  esac
  rm -f "$body"
  return 1
}

configure() {
  local reg_token name labels
  local -a args=()
  reg_token="$(registration_token)" || return 1
  [[ -n "$reg_token" ]] || { log "GitHub returned an empty registration token."; return 1; }
  name="$(runner_name)"
  labels="$(runner_labels)"
  args=(--unattended --replace --url "$URL" --token "$reg_token" --name "$name" --labels "$labels" --work "$WORK_DIR")
  if [[ -z "$REPO" && -n "${RUNNER_GROUP:-}" ]]; then
    args+=(--runnergroup "$RUNNER_GROUP")
  fi
  if is_true "${RUNNER_EPHEMERAL:-false}"; then
    args+=(--ephemeral)
  fi
  if is_true "${RUNNER_DISABLE_UPDATE:-false}"; then
    args+=(--disableupdate)
  fi
  log "Registering runner '${name}' (labels: self-hosted, Linux, X64, ${labels}) with the ${SCOPE} ..."
  if (cd "$RUNNER_DIR" && as_runner ./config.sh "${args[@]}") 2>&1 | sed -u -E 's/--token [^ ]+/--token ***/g' | sed -u 's/^/[config] /' >&2 \
      && is_configured; then
    save_state
    log "Runner registered."
    return 0
  fi
  log "Registration failed (see the [config] lines above). A registration token is valid for one hour only; a PAT avoids this."
  return 1
}

# ---------------------------------------------------------------- run

run_listener() {
  local status=0
  : > "$RUN_LOG"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUN_LOG"
  (cd "$RUNNER_DIR" && exec setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups \
    env -u RUNNER_TOKEN -u GITHUB_TOKEN HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" \
    RUNNER_MANUALLY_TRAP_SIG=1 ./run.sh) > >(tee -a "$RUN_LOG" >&2) 2>&1 &
  RUN_PID=$!
  wait "$RUN_PID" || status=$?
  # A second wait returns the real status if the first was cut short by a signal.
  if kill -0 "$RUN_PID" 2> /dev/null; then
    wait "$RUN_PID" || status=$?
  fi
  RUN_PID=""
  save_state
  return "$status"
}

registration_gone() {
  grep -q -i -E 'registration has been deleted|registration was not found|runner .* not found|invalid_client|Access denied' "$RUN_LOG" 2> /dev/null
}

# shellcheck disable=SC2329 # called from the signal trap
on_signal() {
  STOPPING=1
  log "Stop signal: stopping the runner (a running job is cancelled)."
  if [[ -n "$RUN_PID" ]]; then
    kill -TERM "$RUN_PID" 2> /dev/null || true
    wait "$RUN_PID" 2> /dev/null || true
  fi
  save_state 2> /dev/null || true
  exit 0
}

# Optional distribution packages for jobs, reinstalled after every redeploy.
install_packages() {
  local -a pkgs=()
  local word
  for word in ${APT_PACKAGES//,/ }; do
    if [[ "$word" =~ ^[a-z0-9][a-z0-9+._-]+$ ]]; then
      pkgs+=("$word")
    else
      log "Skipping invalid package name '${word:0:64}'."
    fi
  done
  (( ${#pkgs[@]} > 0 )) || return 0
  log "Installing ${#pkgs[*]} package(s): ${pkgs[*]}"
  if DEBIAN_FRONTEND=noninteractive apt-get update -qq > /tmp/apt.log 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >> /tmp/apt.log 2>&1; then
    log "Packages installed."
  else
    log "WARNING: package installation failed:"
    tail -n 5 /tmp/apt.log >&2 || true
  fi
}

main() {
  trap on_signal TERM INT
  local kind status

  log "GitHub Actions runner $(cat "${RUNNER_DIR}/.version" 2> /dev/null || echo unknown) on $(. /etc/os-release && printf '%s' "$PRETTY_NAME"). No Docker: jobs with 'container:', 'services:' or Docker actions cannot run here."
  prepare_dirs
  restore_state
  if [[ -n "${APT_PACKAGES:-}" ]]; then
    install_packages
  fi
  if ! is_true "${RUNNER_SUDO:-true}"; then
    rm -f /etc/sudoers.d/runner
    log "RUNNER_SUDO=false: jobs run without sudo."
  fi

  if ! parse_url; then
    if is_configured; then
      log "WARNING: GITHUB_URL is not a valid https://{host}/{owner}[/{repo}] URL; using the stored registration for $(configured_url)."
    else
      idle_forever "Not configured: set GITHUB_URL to your repository or organization URL (for example ${PLACEHOLDER_HINT}, got '${GITHUB_URL:-}') and RUNNER_TOKEN, then redeploy. The service stays idle until then."
    fi
  elif is_configured && [[ "$(configured_url)" != "$URL" ]]; then
    log "GITHUB_URL changed from $(configured_url) to ${URL}: registering again."
    forget_state
  fi

  while (( STOPPING == 0 )); do
    if ! is_configured; then
      kind="$(token_kind)"
      if [[ -z "${URL:-}" ]]; then
        idle_forever "The stored registration is gone and GITHUB_URL is not valid. Set GITHUB_URL and RUNNER_TOKEN, then redeploy."
      fi
      if [[ "$kind" == none ]]; then
        idle_forever "Not registered: set RUNNER_TOKEN to a registration token or a personal access token for the ${SCOPE}, then redeploy. The service stays idle until then."
      fi
      if ! configure; then
        backoff
        continue
      fi
    fi

    status=0
    run_listener || status=$?
    (( STOPPING == 0 )) || break
    if is_true "${RUNNER_EPHEMERAL:-false}" && (( status == 0 )); then
      log "Ephemeral runner finished its job: cleaning the work folder and registering again."
      forget_state
      find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2> /dev/null || true
      RETRY_S=$MIN_RETRY_S
      continue
    fi
    if registration_gone; then
      log "GitHub no longer knows this runner (removed in the repository settings?): forgetting the stored registration."
      forget_state
    else
      log "The runner stopped (status ${status})."
    fi
    backoff
  done
}

main "$@"
