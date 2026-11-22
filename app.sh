#!/usr/bin/env bash
set -euo pipefail

INFRA="$(dirname "$(readlink -f "$0")")"
APPS=/srv/apps
SITE="$INFRA/proxy/site.sh"
SITES="$INFRA/proxy/sites"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
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
    [ "$old" = "$domain" ] || bash "$SITE" remove "$old"
  done
  if [ -n "$domain" ]; then
    bash "$SITE" add "$domain" "$name:$port"
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

repo_page() {
  local host path
  if [[ "$1" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$1" =~ ^git@([^:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$1" =~ ^ssh://(git@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[4]}"
  else
    return 0
  fi
  path="${path%/}"
  echo "https://$host/${path%.git}"
}

deploy_key() {
  local key="$HOME/.ssh/deploy-$1" page
  mkdir -p "$HOME/.ssh"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C "$(hostname) $1" -f "$key"
  page="$(repo_page "$2")"
  {
    echo
    echo "No access to $2"
    echo "Either the link has a typo or the repository is private."
    echo "If it is private, give this server read access with a deploy key."
    echo
    case "$page" in
      https://github.com/*)
        echo "1. Open $page/settings/keys/new"
        ;;
      https://gitlab.com/*)
        echo "1. Open $page/-/settings/repository and expand Deploy keys"
        ;;
      *)
        echo "1. Open the repository settings -> Deploy keys -> Add deploy key"
        ;;
    esac
    echo "2. Title: $(hostname) $1"
    echo "3. Key: paste this line"
    echo
    cat "$key.pub"
    echo
    echo "4. Leave \"Allow write access\" off, the server only needs to read. Click Add key."
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
  local log denied=""
  log="$(mktemp)"
  if docker compose "$@" 2>&1 | tee "$log"; then
    rm -f "$log"
    return
  fi
  grep -qiE 'unauthorized|denied' "$log" && denied=1
  rm -f "$log"
  if [ -n "$denied" ] && [ -z "${COMPOSE_RETRY:-}" ]; then
    echo
    echo "Docker could not download the images: they are private, and this server is not logged in to the registry."
    if [ "$(ask "Log in to ghcr.io now? Y/n" y)" != n ]; then
      login ghcr.io
      COMPOSE_RETRY=1 compose "$@"
      return
    fi
    echo "Later: app login. Or make the packages public on GitHub."
  fi
  exit 1
}

login() {
  local registry="${1:-ghcr.io}" user token out
  if [ "$registry" = ghcr.io ]; then
    cat << EOF

To pull private images from ghcr.io the server needs a GitHub token that can only read packages.

1. Open https://github.com/settings/tokens/new?scopes=read:packages&description=$(hostname)
   or by hand: GitHub -> Settings -> Developer settings -> Personal access tokens -> Tokens (classic) -> Generate new token (classic).
2. Only read:packages should be checked. Expiration: "No expiration", otherwise pulls stop working the day it expires.
3. Click Generate token and copy it, GitHub shows it only once.

It has to be a classic token: fine-grained tokens do not work with ghcr.io.

EOF
  fi
  repair_docker_config
  if jq -e --arg r "$registry" '.auths[$r]' "$DOCKER_CONFIG_FILE" > /dev/null 2>&1; then
    echo "This server is already logged in to $registry, a new login replaces it."
  fi
  user="$(ask "GitHub username")"
  [ -n "$user" ] || die "Cancelled"
  read -rsp "Token (not shown while typing): " token < /dev/tty
  echo >&2
  [ -n "$token" ] || die "Cancelled"

  if ! out="$(printf '%s' "$token" | docker login "$registry" -u "$user" --password-stdin 2>&1)"; then
    if grep -qi 'saving credentials\|credential' <<< "$out" && jq -e '.credsStore // .credHelpers' "$DOCKER_CONFIG_FILE" > /dev/null 2>&1; then
      echo "Docker could not save the token through its credential helper, saving it in $DOCKER_CONFIG_FILE instead"
      drop_credential_helper
      out="$(printf '%s' "$token" | docker login "$registry" -u "$user" --password-stdin 2>&1)" || {
        echo "$out" >&2
        die "Login to $registry failed"
      }
    else
      echo "$out" >&2
      die "$registry did not accept this username and token"
    fi
  fi

  if ! jq -e --arg r "$registry" '.auths[$r]' "$DOCKER_CONFIG_FILE" > /dev/null 2>&1; then
    die "Docker says the login worked, but nothing was saved in $DOCKER_CONFIG_FILE"
  fi
  echo "Logged in to $registry as $user, saved in $DOCKER_CONFIG_FILE"
}

logins() {
  local helper registry auth user
  echo "Registry logins of $(whoami) ($DOCKER_CONFIG_FILE):"
  if [ ! -f "$DOCKER_CONFIG_FILE" ] || ! jq -e '(.auths // {}) | length > 0' "$DOCKER_CONFIG_FILE" > /dev/null 2>&1; then
    jq -e . "$DOCKER_CONFIG_FILE" > /dev/null 2>&1 || [ ! -f "$DOCKER_CONFIG_FILE" ] || die "The file is damaged. app login repairs it."
    echo "none. Log in: app login"
    return
  fi

  helper="$(jq -r '.credsStore // empty' "$DOCKER_CONFIG_FILE")"
  printf '%-30s %s\n' REGISTRY USER
  jq -r '.auths | to_entries[] | [.key, (.value.auth // "")] | @tsv' "$DOCKER_CONFIG_FILE" |
    while IFS=$'\t' read -r registry auth; do
      if [ -n "$auth" ]; then
        user="$(printf '%s' "$auth" | base64 -d 2> /dev/null | cut -d: -f1)"
      elif [ -n "$helper" ] && command -v "docker-credential-$helper" > /dev/null; then
        user="$(docker-credential-"$helper" list 2> /dev/null | jq -r --arg r "$registry" '.[$r] // .["https://" + $r] // "?"')"
      else
        user="? (token is missing, log in again: app login)"
      fi
      printf '%-30s %s\n' "$registry" "${user:-?}"
    done
}

logout() {
  local registry="${1:-}" registries=()
  if [ -f "$DOCKER_CONFIG_FILE" ]; then
    mapfile -t registries < <(jq -r '(.auths // {}) | keys[]' "$DOCKER_CONFIG_FILE" 2> /dev/null)
  fi
  [ ${#registries[@]} -gt 0 ] || die "$(whoami) is not logged in to any registry"
  if [ -z "$registry" ]; then
    if [ ${#registries[@]} -eq 1 ]; then
      registry="${registries[0]}"
    else
      registry="$(ask "Log out of which registry (${registries[*]})" ghcr.io)"
    fi
  fi
  printf '%s\n' "${registries[@]}" | grep -qxF "$registry" || die "Not logged in to $registry. See: app logins"
  docker logout "$registry" > /dev/null
  echo "Logged out of $registry"
  echo "Running apps keep working. New private images from $registry will not download until: app login"
}

repair_docker_config() {
  local helper
  [ -f "$DOCKER_CONFIG_FILE" ] || return 0
  if ! jq -e . "$DOCKER_CONFIG_FILE" > /dev/null 2>&1; then
    mv "$DOCKER_CONFIG_FILE" "$DOCKER_CONFIG_FILE.broken"
    echo "$DOCKER_CONFIG_FILE was damaged, moved it to $DOCKER_CONFIG_FILE.broken"
    return
  fi
  helper="$(jq -r '.credsStore // empty' "$DOCKER_CONFIG_FILE")"
  if [ -n "$helper" ] && ! command -v "docker-credential-$helper" > /dev/null; then
    echo "Docker is set to keep passwords in docker-credential-$helper, which is not installed here. Turning that off."
    drop_credential_helper
  fi
}

drop_credential_helper() {
  local tmp
  tmp="$(mktemp)"
  jq 'del(.credsStore, .credHelpers)' "$DOCKER_CONFIG_FILE" > "$tmp"
  mv "$tmp" "$DOCKER_CONFIG_FILE"
  chmod 600 "$DOCKER_CONFIG_FILE"
}

running_images() {
  docker compose ps -q | xargs -r docker inspect -f '{{.Name}} {{.Image}}' | sort
}

update() {
  local project built before
  open_app "${1:-}"
  before="$(running_images)"
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
  if [ -n "$before" ] && [ "$(running_images)" = "$before" ]; then
    echo
    echo "Nothing new to run: the images are the same as before."
    echo "If you just pushed, the image build may not be finished yet. Check Actions on GitHub and run app update again when it is green."
  fi
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
    bash "$SITE" remove "$domain"
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
    bash "$INFRA/app.sh" update "$name" || failed+=("$name")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    die "Failed: ${failed[*]}"
  fi
}

self_update() {
  local before answer
  if ! git -C "$INFRA" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    die "$INFRA is not a git clone, so there is nothing to pull. Clone the repository there again, see README."
  fi
  git -C "$INFRA" config core.fileMode false
  if [ -n "$(git -C "$INFRA" status --porcelain --untracked-files=no)" ]; then
    echo "Files in $INFRA were changed on this server:"
    git -C "$INFRA" status --short --untracked-files=no
    answer="$(ask "Discard these changes and take the version from GitHub? y/N" n)"
    [ "$answer" = y ] || die "Cancelled. See the changes: git -C $INFRA diff"
    git -C "$INFRA" checkout -- .
  fi
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
    login) login "$@" ;;
    logins) logins ;;
    logout) logout "$@" ;;
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
app login [registry]          log in to ghcr.io to pull private images, with instructions
app logins                    registries this server is logged in to, and as whom
app logout [registry]         forget the login, for example to switch to another GitHub account
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