ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-bookworm

ARG PATRONI_VERSION=4.1.4

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv curl jq less procps iputils-ping pgbackrest \
 && rm -rf /var/lib/apt/lists/*

# Isolated venv keeps pip away from Debian's externally managed environment.
RUN python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir \
      "patroni[etcd3]==${PATRONI_VERSION}" psycopg2-binary
ENV PATH="/opt/patroni/bin:${PATH}"

COPY patroni.yml.tmpl /etc/patroni.yml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && mkdir -p /var/lib/postgresql/data \
 && chown -R postgres:postgres /var/lib/postgresql/data /etc/patroni.yml.tmpl

USER postgres
ENTRYPOINT ["/entrypoint.sh"]
