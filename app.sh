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
  docker compose up -d --remove-orphans

  for old in $(domains_of "$name"); do
    [ "$old" = "$domain" ] || "$SITE" remove "$old"
  done
  if [ -n "$domain" ]; then
    "$SITE" add "$domain" "$name:$port"
  fi
}

deploy() {
  local url="${1:-}" name
  [ -n "$url" ] || die "Usage: app deploy <git-url> [name]"
  name="${2:-$(basename "$url" .git | tr '[:upper:]_' '[:lower:]-')}"
  name="$(ask "App name" "$name")"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Name may only have lowercase letters, digits and dashes"
  [ ! -e "$APPS/$name" ] || die "$APPS/$name already exists. To set it up again: app setup $name"
  git clone "$url" "$APPS/$name"
  cd "$APPS/$name"
  configure "$name"
}

update() {
  local project built
  open_app "${1:-}"
  [ ! -d .git ] || git pull --ff-only
  docker compose pull --ignore-buildable --quiet
  project="$(docker compose config --format json | jq -r '.name')"
  mapfile -t built < <(docker compose config --format json | jq -r --arg p "$project" \
    '.services | to_entries[] | select(.value.build != null and (.value.image == null or .value.image == ($p + "-" + .key))) | .key')
  if [ ${#built[@]} -gt 0 ]; then
    docker compose build "${built[@]}"
  fi
  docker compose up -d --remove-orphans
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

command="${1:-}"
shift || true
case "$command" in
  deploy) deploy "$@" ;;
  setup)
    open_app "${1:-}"
    configure "$1"
    ;;
  update) update "$@" ;;
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
app list                      apps, how many containers are up, domains
app logs <name> [service]     follow logs
app status <name>             containers of the app
app restart|stop|start <name>
app remove <name>             stop, drop its domains, delete the folder
EOF
    [ -z "$command" ] || exit 1
    ;;
esac
