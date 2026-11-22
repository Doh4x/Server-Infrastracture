#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

die() {
  echo "$*" >&2
  exit 1
}

reload() {
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
}

zone_of() {
  local domain="$1" file zone
  for file in certs/*.pem; do
    [ -e "$file" ] || continue
    zone="$(basename "$file" .pem)"
    if [ "$domain" = "$zone" ] || [[ "$domain" == *".$zone" && "${domain%".$zone"}" != *.* ]]; then
      echo "$zone"
      return
    fi
  done
}

target_of() {
  grep -o 'reverse_proxy [^ ]*' "$1" | cut -d' ' -f2
}

write_site() {
  local domain="$1" target="$2" zone
  zone="$(zone_of "$domain")"
  {
    echo "$domain {"
    if [ -n "$zone" ]; then
      echo "	tls /etc/caddy/certs/$zone.pem /etc/caddy/certs/$zone.key"
    fi
    echo "	encode gzip"
    echo "	reverse_proxy $target {"
    echo "		header_up X-Forwarded-For {client_ip}"
    echo "	}"
    echo "}"
  } > "sites/$domain.caddy"
}

rewrite_all() {
  local file
  for file in sites/*.caddy; do
    [ -e "$file" ] || continue
    write_site "$(basename "$file" .caddy)" "$(target_of "$file")"
  done
}

read_pem() {
  local line
  : > "$1"
  while IFS= read -r line < /dev/tty; do
    line="${line%$'\r'}"
    if [ -z "$line" ] && [ ! -s "$1" ]; then
      continue
    fi
    echo "$line" >> "$1"
    [[ "$line" != -----END* ]] || break
  done
}

install_cert() {
  local zone="$1" pem="certs/$1.pem.new" key="certs/$1.key.new"
  mkdir -p certs
  echo "Paste the Origin Certificate (everything from -----BEGIN CERTIFICATE----- to -----END CERTIFICATE-----):"
  read_pem "$pem"
  echo "Now paste the Private Key:"
  read_pem "$key"
  chmod 600 "$key"

  openssl x509 -in "$pem" -noout 2> /dev/null || {
    rm -f "$pem" "$key"
    die "This is not a certificate"
  }
  openssl pkey -in "$key" -noout 2> /dev/null || {
    rm -f "$pem" "$key"
    die "This is not a private key"
  }
  if [ "$(openssl x509 -in "$pem" -noout -pubkey)" != "$(openssl pkey -in "$key" -pubout)" ]; then
    rm -f "$pem" "$key"
    die "The key does not belong to this certificate"
  fi

  mv "$pem" "certs/$zone.pem"
  mv "$key" "certs/$zone.key"
  rewrite_all
  reload
  echo "Certificate for $zone installed, $(openssl x509 -in "certs/$zone.pem" -noout -enddate | cut -d= -f2)"
}

list_certs() {
  local file
  for file in certs/*.pem; do
    [ -e "$file" ] || continue
    echo "$(basename "$file" .pem): $(openssl x509 -in "$file" -noout -subject -enddate | tr '\n' ' ')"
  done
}

main() {
  local domain target file
  case "${1:-}" in
    add)
      domain="${2:?usage: site add <domain> <container:port>}"
      target="${3:?usage: site add <domain> <container:port>}"
      write_site "$domain" "$target"
      reload
      if [ -n "$(zone_of "$domain")" ]; then
        echo "https://$domain -> $target (origin certificate)"
      else
        echo "https://$domain -> $target"
      fi
      ;;
    logs)
      docker compose logs -f --tail 100
      ;;
    restart)
      docker compose restart caddy
      ;;
    remove)
      domain="${2:?usage: site remove <domain>}"
      rm -f "sites/$domain.caddy"
      reload
      echo "removed $domain"
      ;;
    list)
      for file in sites/*.caddy; do
        [ -e "$file" ] || continue
        domain="$(basename "$file" .caddy)"
        if grep -q '	tls ' "$file"; then
          echo "$domain -> $(target_of "$file")  (origin certificate)"
        else
          echo "$domain -> $(target_of "$file")"
        fi
      done
      ;;
    cert)
      if [ -n "${2:-}" ]; then
        install_cert "$2"
      else
        list_certs
      fi
      ;;
    refresh)
      rewrite_all
      reload
      ;;
    reload)
      reload
      ;;
    *)
      cat << 'EOF'
site add <domain> <container:port>   send a domain to a container
site remove <domain>
site list
site cert <zone>                     install a Cloudflare Origin certificate, for example: site cert example.com
site cert                            installed certificates and when they expire
site logs                            proxy logs: certificates, 502 errors
site restart                         restart the proxy
EOF
      exit 1
      ;;
  esac
}

main "$@"; exit
