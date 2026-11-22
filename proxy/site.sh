#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

reload() {
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
}

case "${1:-}" in
  add)
    domain="${2:?usage: site.sh add <domain> <container:port>}"
    target="${3:?usage: site.sh add <domain> <container:port>}"
    printf '%s {\n\tencode gzip\n\treverse_proxy %s\n}\n' "$domain" "$target" > "sites/$domain.caddy"
    reload
    echo "https://$domain -> $target"
    ;;
  remove)
    domain="${2:?usage: site.sh remove <domain>}"
    rm -f "sites/$domain.caddy"
    reload
    echo "removed $domain"
    ;;
  list)
    for file in sites/*.caddy; do
      [ -e "$file" ] || continue
      domain="$(basename "$file" .caddy)"
      target="$(grep -o 'reverse_proxy [^ ]*' "$file" | cut -d' ' -f2)"
      echo "$domain -> $target"
    done
    ;;
  reload)
    reload
    ;;
  *)
    echo "usage: site.sh add <domain> <container:port> | remove <domain> | list | reload"
    exit 1
    ;;
esac
