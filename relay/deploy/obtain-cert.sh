#!/usr/bin/env bash
# Obtain the Let's Encrypt certificate for the relay host via the Apache webroot that
# already answers :80 on this box (certbot standalone can't be used — Apache owns :80).
#
# On this virtualmin server the per-domain vhosts bind to specific IPs, so a lone
# "<VirtualHost *:80>" for the relay host is never matched — requests for the relay
# subdomain fall through to the parent domain's vhost. The reliable path is therefore to
# serve the ACME challenge from the PARENT domain's existing docroot.
#
# Run on the server as root. Idempotent: re-running renews/keeps the cert.
set -euo pipefail

DOMAIN="${1:-remrem.accessy.org}"
# Parent domain whose Apache docroot serves the challenge (the relay host falls through
# to it). Override with the second argument if the parent differs.
PARENT="${2:-accessy.org}"
EMAIL="${LE_EMAIL:-admin@${PARENT}}"

VHOST_CONF="/etc/apache2/sites-enabled/${PARENT}.conf"
WEBROOT="$(grep -i 'DocumentRoot' "${VHOST_CONF}" | head -1 | awk '{print $2}')"
if [[ -z "${WEBROOT}" || ! -d "${WEBROOT}" ]]; then
    echo "Could not determine the docroot for ${PARENT} from ${VHOST_CONF}" >&2
    exit 1
fi

echo ">> Serving the ACME challenge from ${WEBROOT} (parent domain ${PARENT})"
mkdir -p "${WEBROOT}/.well-known/acme-challenge"

echo ">> Requesting certificate for ${DOMAIN}"
certbot certonly --webroot -w "${WEBROOT}" -d "${DOMAIN}" \
    --non-interactive --agree-tos --email "${EMAIL}" --keep-until-expiring

echo ">> Certificate is at /etc/letsencrypt/live/${DOMAIN}/"
echo ">> Certbot's systemd timer will renew it automatically."
