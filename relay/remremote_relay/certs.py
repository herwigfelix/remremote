"""TLS certificate provider with hot reload.

Let's Encrypt (via certbot on the host — Apache owns :80 here) renews the cert files
under the mounted directory every ~60 days. This watches their modification time and
reloads them into the live SSLContext, so new TLS handshakes pick up the renewed cert
without restarting the relay. Existing connections keep the old cert until they close,
which is exactly what we want.
"""

import logging
import os
import ssl
from typing import Optional, Tuple

log = logging.getLogger("remremote.certs")


class CertProvider:
    def __init__(self, certfile: str, keyfile: Optional[str] = None):
        self.certfile = certfile
        #: Let's Encrypt ships fullchain.pem + privkey.pem separately; a combined PEM
        #: (key + cert in one file) is also accepted by passing only certfile.
        self.keyfile = keyfile
        self._context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self._context.minimum_version = ssl.TLSVersion.TLSv1_2
        # Advertise the ALPN the add-on and app negotiate; harmless to stock clients.
        try:
            self._context.set_alpn_protocols(["nvdaremote/2.0"])
        except NotImplementedError:
            pass
        self._mtimes: Tuple[float, float] = (0.0, 0.0)
        self._load()

    @property
    def context(self) -> ssl.SSLContext:
        return self._context

    def _current_mtimes(self) -> Tuple[float, float]:
        cert_m = os.path.getmtime(self.certfile)
        key_m = os.path.getmtime(self.keyfile) if self.keyfile else cert_m
        return (cert_m, key_m)

    def _load(self):
        self._context.load_cert_chain(certfile=self.certfile, keyfile=self.keyfile)
        self._mtimes = self._current_mtimes()
        log.info("loaded TLS certificate from %s", self.certfile)

    def reload_if_changed(self):
        try:
            if self._current_mtimes() != self._mtimes:
                self._load()
                log.info("TLS certificate reloaded after renewal")
        except OSError:
            # A renewal in progress may briefly move files; try again next tick.
            log.debug("certificate files temporarily unavailable during reload check")
