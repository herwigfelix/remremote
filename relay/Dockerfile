# remremote relay — pure standard-library Python, no third-party dependencies.
FROM python:3.12-slim

RUN useradd --system --no-create-home --uid 10037 relay

WORKDIR /app
COPY remremote_relay ./remremote_relay

USER relay

# Control (TCP) and audio (UDP) share the same port number by default.
EXPOSE 6837/tcp
EXPOSE 6837/udp

ENTRYPOINT ["python", "-m", "remremote_relay"]
