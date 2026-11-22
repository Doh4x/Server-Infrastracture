#!/usr/bin/env bash
set -euo pipefail

INFRA="$(dirname "$(readlink -f "$0")")"
APPS=/srv/apps
SITE="$INFRA/proxy/site.sh"
SITES="$INFRA/proxy/sites"
COMPOSE_FILES=(compose.prod.yaml compose.prod.yml docker-compose.prod.yml compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

die() {
  echo "$*" >&2
  exit 1
}

ask() {
  local answer
  if [ -n "${2:-}" ]; then
    read -rp "$1 [$2]: " answer < /dev/tty
  else
    read -rp "$1: " answer < /dev/tty
  fi
  echo "${answer:-${2:-}}"
}

open_app() {
  [ -n "${1:-}" ] || die "Which app? See: app list"
  [ -d "$APPS/$1" ] || die "No app $1 in $APPS"
  cd "$APPS/$1"
}

domains_of() {
  grep -l "reverse_proxy $1:" "$SITES"/*.caddy 2> /dev/null | xargs -r -n1 basename | sed 's/\.caddy$//' || true
}

env_value() {
  [ -f .env ] || return 0
  grep -m1 "^$1=" .env | cut -d= -f2- || true
}

configure() {
  local name="$1" file main json public port domain old key value line
  local files=() services=()

  for file in "${COMPOSE_FILES[@]}"; do
    [ -f "$file" ] && files+=("$file")
  done
  [ ${#files[@]} -gt 0 ] || die "No compose file in $(pwd)"
  main="${files[0]}"
  if [ ${#files[@]} -gt 1 ]; then
    echo "Compose files here: ${files[*]}"
    main="$(ask "Which one to run" "$main")"
  fi
  [ -f "$main" ] || die "No file $main"

  local env=()
  if [ -f .env.example ]; then
    echo "Settings from .env.example, Enter keeps the value in brackets:"
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
      key="${BASH_REMATCH[1]}"
      [ "$key" = COMPOSE_FILE ] && continue
      old="$(env_value "$key")"
      value="$(ask "  $key" "${old:-${BASH_REMATCH[2]}}")"
      env+=("$key=$value")
    done < .env.example
  fi
  printf '%s\n' "${env[@]}" "COMPOSE_FILE=$main" > .env

  json="$(docker compose config --format json)"
  mapfile -t services < <(jq -r '.services | keys[]' <<< "$json")
  public="$(jq -r '[.services | to_entries[] | select(.value.networks.proxy != null) | .key][0] // empty' <<< "$json")"
  [ -n "$public" ] || public="$(jq -r '[.services | to_entries[] | select(.value.ports != null) | .key][0] // empty' <<< "$json")"
  [ -n "$public" ] || public="${services[0]}"
  if [ ${#services[@]} -gt 1 ]; then
    public="$(ask "Service that faces the internet (${services[*]})" "$public")"
  fi
  jq -e --arg s "$public" '.services[$s]' <<< "$json" > /dev/null || die "No service $public"

  port="$(jq -r --arg s "$public" '.services[$s] | (.ports[0].target // .expose[0] // 80) | tostring | split("/")[0]' <<< "$json")"
  port="$(ask "Port $public listens on inside the container" "$port")"

  cat > compose.proxy.yaml << EOF
services:
  $public:
    ports: !reset []
    networks:
      default:
      proxy:
        aliases:
          - $name

networks:
  proxy:
    external: true
EOF
  printf '%s\n' "${env[@]}" "COMPOSE_FILE=$main:compose.proxy.yaml" > .env

  if [ -d .git ]; then
    for file in .env compose.proxy.yaml; do
      grep -qx "$file" .git/info/exclude 2> /dev/null || echo "$file" >> .git/info/exclude
    done
  fi

  old="$(domains_of "$name" | head -n1)"
  domain="$(ask "Domain, empty to leave without one" "$old")"

  echo "Starting $name"
  start

  for old in $(domains_of "$name"); do
    [ "$old" = "$domain" ] || "$SITE" remove "$old"
  done
  if [ -n "$domain" ]; then
    "$SITE" add "$domain" "$name:$port"
  fi
}

ssh_url() {
  if [[ "$1" =~ ^https?://([^/]+)/(.+)$ ]]; then
    local path="${BASH_REMATCH[2]%/}"
    echo "git@${BASH_REMATCH[1]}:${path%.git}.git"
  elif [[ "$1" == git@* || "$1" == ssh://* ]]; then
    echo "$1"
  fi
}

deploy_key() {
  local key="$HOME/.ssh/deploy-$1"
  mkdir -p "$HOME/.ssh"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C "$(hostname) $1" -f "$key"
  {
    echo
    echo "No access to $2"
    echo "Either the link has a typo or the repository is private."
    echo "If it is private, give this server read access:"
    echo "repository on GitHub -> Settings -> Deploy keys -> Add deploy key, paste this line:"
    echo
    cat "$key.pub"
    echo
  } >&2
  ask "Press Enter when it is added" > /dev/null
  echo "ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
}

can_reach() {
  GIT_TERMINAL_PROMPT=0 git -C "$1" ls-remote -q origin HEAD > /dev/null 2>&1
}

ensure_access() {
  local dir="$1" name="$2" url ssh command
  can_reach "$dir" && return
  url="$(git -C "$dir" remote get-url origin)"
  ssh="$(ssh_url "$url")"
  [ -n "$ssh" ] || die "No access to $url"
  command="$(deploy_key "$name" "$url")"
  git -C "$dir" remote set-url origin "$ssh"
  git -C "$dir" config core.sshCommand "$command"
  can_reach "$dir" || die "Still no access. Check the link and the deploy key."
}

clone() {
  local url="$1" name="$2" dir="$APPS/$2" ssh command
  echo "Cloning $url"
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    git clone -q "$url" "$dir" 2> /dev/null; then
    return
  fi
  ssh="$(ssh_url "$url")"
  [ -n "$ssh" ] || die "Could not clone $url. Check the link."
  command="$(deploy_key "$name" "$url")"
  GIT_SSH_COMMAND="$command" git clone -q "$ssh" "$dir" || die "Still no access. Check the link and the deploy key."
  git -C "$dir" config core.sshCommand "$command"
}

is_url() {
  [[ "$1" == *://* || "$1" == git@* ]]
}

deploy() {
  local url="${1:-}" name="${2:-}"
  if ! is_url "$url" && is_url "$name"; then
    url="$2"
    name="$1"
  fi
  is_url "$url" || die "Usage: app deploy <git-url> [name]"
  if [ -z "$name" ]; then
    name="$(ask "App name" "$(basename "${url%/}" .git | tr '[:upper:]_' '[:lower:]-')")"
  fi
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Name may only have lowercase letters, digits and dashes"
  [ ! -e "$APPS/$name" ] || die "$APPS/$name already exists. To set it up again: app setup $name"
  clone "$url" "$name"
  cd "$APPS/$name"
  configure "$name"
}

start() {
  compose up -d --remove-orphans
}

compose() {
  local log
  log="$(mktemp)"
  if ! docker compose "$@" 2>&1 | tee "$log"; then
    if grep -qiE 'unauthorized|denied' "$log"; then
      echo
      echo "Docker could not download the images: they are private."
      echo "Make the packages public on GitHub (profile -> Packages -> package -> Package settings -> Change visibility),"
      echo "or log in once: docker login ghcr.io -u <github-login>, with a token that has read:packages."
    fi
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

update() {
  local project built
  open_app "${1:-}"
  if [ -d .git ]; then
    ensure_access . "$1"
    GIT_TERMINAL_PROMPT=0 git pull --ff-only
  fi
  compose pull --ignore-buildable --quiet
  project="$(docker compose config --format json | jq -r '.name')"
  mapfile -t built < <(docker compose config --format json | jq -r --arg p "$project" \
    '.services | to_entries[] | select(.value.build != null and (.value.image == null or .value.image == ($p + "-" + .key))) | .key')
  if [ ${#built[@]} -gt 0 ]; then
    docker compose build "${built[@]}"
  fi
  start
}

list() {
  local dir name running total
  printf '%-20s %-8s %s\n' APP UP DOMAINS
  for dir in "$APPS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    running="$(cd "$dir" && docker compose ps -q --status running 2> /dev/null | wc -l)"
    total="$(cd "$dir" && docker compose ps -aq 2> /dev/null | wc -l)"
    printf '%-20s %-8s %s\n' "$name" "$running/$total" "$(domains_of "$name" | xargs)"
  done
}

remove() {
  local name="${1:-}" domain answer
  open_app "$name"
  answer="$(ask "Type $name to remove it")"
  [ "$answer" = "$name" ] || die "Cancelled"
  answer="$(ask "Delete its data volumes too? y/N" n)"
  if [ "$answer" = y ]; then
    docker compose down -v
  else
    docker compose down
  fi
  for domain in $(domains_of "$name"); do
    "$SITE" remove "$domain"
  done
  cd "$APPS"
  rm -rf "${APPS:?}/$name" 2> /dev/null || sudo rm -rf "${APPS:?}/$name"
  echo "Removed $name"
}

update_all() {
  local dir name failed=()
  for dir in "$APPS"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    echo "== $name"
    "$(readlink -f "$0")" update "$name" || failed+=("$name")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    die "Failed: ${failed[*]}"
  fi
}

self_update() {
  local before
  ensure_access "$INFRA" infra
  before="$(git -C "$INFRA" rev-parse HEAD)"
  GIT_TERMINAL_PROMPT=0 git -C "$INFRA" pull --ff-only
  if [ "$(git -C "$INFRA" rev-parse HEAD)" = "$before" ]; then
    echo "server-infra is already up to date"
    return
  fi
  git -C "$INFRA" log --oneline "$before..HEAD"
  sudo bash "$INFRA/setup.sh"
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    deploy) deploy "$@" ;;
    setup)
      open_app "${1:-}"
      configure "$1"
      ;;
    update)
      if [ "${1:-}" = --all ]; then
        update_all
      else
        update "$@"
      fi
      ;;
    self-update) self_update ;;
    list) list ;;
    logs)
      open_app "${1:-}"
      shift
      docker compose logs -f --tail 100 "$@"
      ;;
    status)
      open_app "${1:-}"
      docker compose ps
      ;;
    restart)
      open_app "${1:-}"
      docker compose restart
      ;;
    stop)
      open_app "${1:-}"
      docker compose stop
      ;;
    start)
      open_app "${1:-}"
      docker compose up -d
      ;;
    remove) remove "$@" ;;
    *)
      cat << 'EOF'
app deploy <git-url> [name]   clone into /srv/apps and set it up
app setup <name>              run the setup questions again
app update <name>             git pull, fresh images, restart
app update --all              the same for every app
app self-update               git pull of server-infra and setup.sh again
app list                      apps, how many containers are up, domains
app logs <name> [service]     follow logs
app status <name>             containers of the app
app restart|stop|start <name>
app remove <name>             stop, drop its domains, delete the folder
EOF
      [ -z "$command" ] || exit 1
      ;;
  esac
}

main "$@"; exit