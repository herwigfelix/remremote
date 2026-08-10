# Deploying the remremote relay (remrem.accessy.org)

Target: `ns3.blindandcool.net` (Debian 12, Docker present, Apache/virtualmin on :80/:443,
BIND for accessy.org). The relay listens on TCP **6837** (control, NVDA-Remote compatible)
and UDP **6837** (audio). It replaces the old `NVDARemoteServer` on the same port.

Because the relay speaks the stock NVDA Remote protocol, existing NVDA Remote / TeleNVDA
users keep working — only the hostname they point at changes to `remrem.accessy.org`.

## 1. DNS

Add an A record for `remrem` to the `accessy.org` zone (managed by BIND/virtualmin,
`/var/lib/bind/accessy.org.hosts`), pointing at the server's public IP, then bump the
zone serial and `rndc reload accessy.org`. Verify with `dig +short remrem.accessy.org`.

## 2. Certificate (Let's Encrypt)

Apache owns :80, so use the webroot flow rather than certbot standalone:

```
sudo LE_EMAIL=you@example.org bash deploy/obtain-cert.sh remrem.accessy.org
```

This drops a tiny :80 vhost serving only `/.well-known/acme-challenge/`, obtains the cert
to `/etc/letsencrypt/live/remrem.accessy.org/`, and leaves certbot's renewal timer to keep
it fresh. The relay hot-reloads the cert when it renews (no restart needed).

## 3. Retire the old server

```
systemctl stop NVDARemoteServer
systemctl disable NVDARemoteServer
```

Its files stay in `/usr/share/NVDARemoteServer/` (and a backup is taken by the deploy
script) so it can be restored if needed.

## 4. Start the relay

```
cd /opt/remremote-relay
docker compose up -d --build
docker compose logs -f
```

The compose file uses host networking (so the UDP relay sees real client addresses) and
mounts `/etc/letsencrypt` read-only.

## 5. Verify

```
# TLS control port answers:
openssl s_client -connect remrem.accessy.org:6837 -servername remrem.accessy.org </dev/null | head
# Fingerprint (clients pin this on first connect):
echo | openssl s_client -connect remrem.accessy.org:6837 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

Then connect a real NVDA Remote / remremote client to `remrem.accessy.org` and, for audio,
a remremote client on each end over the relay.
