ARG PYTHON_VERSION=3.12

FROM python:${PYTHON_VERSION}-slim-bookworm AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libffi-dev \
    && rm -rf /var/lib/apt/lists/*
COPY src/server/reqsNonPi.txt /tmp/reqsNonPi.txt
RUN pip wheel -r /tmp/reqsNonPi.txt -w /wheels

FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime
ARG RH_VERSION=dev
ARG RH_SOURCE=
LABEL org.opencontainers.image.title="RotorHazard" \
      org.opencontainers.image.source="${RH_SOURCE}" \
      org.opencontainers.image.version="${RH_VERSION}" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY src/server/reqsNonPi.txt /tmp/reqsNonPi.txt
RUN --mount=type=bind,from=builder,source=/wheels,target=/wheels \
    pip install --no-index --find-links=/wheels -r /tmp/reqsNonPi.txt \
    && rm /tmp/reqsNonPi.txt

RUN groupadd --gid 1000 rotorhazard \
    && useradd --uid 1000 --gid 1000 --groups dialout --create-home --shell /bin/sh rotorhazard \
    && mkdir -p /data /app \
    && chown 1000:1000 /data

COPY src/server /app/src/server
COPY src/interface /app/src/interface
COPY doc /app/doc
COPY firmware /app/firmware
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && pip freeze > /app/requirements.lock.txt

ENV RH_DATA_DIR=/data \
    PIP_USER=1 \
    PYTHONUSERBASE=/data/python \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app/src/server
VOLUME /data
EXPOSE 5000
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["python", "server.py"]
