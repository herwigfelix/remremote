"""Entry point: run the control relay (TLS/TCP) and the audio relay (UDP) together.

Configuration via environment variables (all optional except the certificate):

    REMREMOTE_PORT          TCP control port and UDP audio port (default 6837)
    REMREMOTE_UDP_PORT      override the UDP audio port (default: same as REMREMOTE_PORT)
    REMREMOTE_BIND          bind address (default: all interfaces)
    REMREMOTE_TLS_CERT      path to the certificate / fullchain PEM (required)
    REMREMOTE_TLS_KEY       path to the private key PEM (omit if combined into the cert)
    REMREMOTE_MOTD          message of the day shown to clients on join
    REMREMOTE_MOTD_FORCE    "1" to force the MOTD every time (default: honour the client)
    REMREMOTE_LOG_LEVEL     Python log level name (default INFO)
"""

import asyncio
import logging
import os
import signal

from .audio import start_audio_relay
from .certs import CertProvider
from .control import ControlRelay


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    try:
        return int(value) if value else default
    except ValueError:
        return default


async def _cert_reload_loop(provider: CertProvider):
    while True:
        await asyncio.sleep(3600)
        provider.reload_if_changed()


async def main():
    logging.basicConfig(
        level=getattr(logging, os.environ.get("REMREMOTE_LOG_LEVEL", "INFO").upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    log = logging.getLogger("remremote")

    certfile = os.environ.get("REMREMOTE_TLS_CERT")
    if not certfile:
        raise SystemExit("REMREMOTE_TLS_CERT is required (path to the certificate PEM)")
    keyfile = os.environ.get("REMREMOTE_TLS_KEY") or None

    port = _env_int("REMREMOTE_PORT", 6837)
    udp_port = _env_int("REMREMOTE_UDP_PORT", port)
    bind = os.environ.get("REMREMOTE_BIND", "")

    provider = CertProvider(certfile=certfile, keyfile=keyfile)
    control = ControlRelay(
        cert_provider=provider,
        host=bind,
        port=port,
        motd=os.environ.get("REMREMOTE_MOTD", ""),
        motd_force_display=os.environ.get("REMREMOTE_MOTD_FORCE", "") == "1",
    )

    await control.start()
    audio_transport = await start_audio_relay(bind, udp_port)
    asyncio.create_task(_cert_reload_loop(provider))
    log.info("remremote relay ready (control TCP/%d, audio UDP/%d)", port, udp_port)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    await stop.wait()
    log.info("shutting down")
    audio_transport.close()


if __name__ == "__main__":
    asyncio.run(main())
