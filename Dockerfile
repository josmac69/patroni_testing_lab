FROM postgres:16

# Install Python, pip, and utilities
RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-venv \
    python3-dev \
    curl \
    iputils-ping \
    jq \
    dnsutils \
    netcat-openbsd \
    iproute2 \
    procps \
    less \
    vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# Install etcdctl binary
RUN curl -L https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz -o /tmp/etcd.tar.gz && \
    tar -xzvf /tmp/etcd.tar.gz -C /tmp && \
    mv /tmp/etcd-v3.5.12-linux-amd64/etcdctl /usr/local/bin/ && \
    rm -rf /tmp/etcd*

# Install Patroni and its dependencies globally
# --break-system-packages is required for Debian Bookworm PEP 668 compliance
RUN pip3 install --break-system-packages "patroni[etcd3]" psycopg2-binary

# Create symlink for pctl to patronictl
RUN ln -s /usr/local/bin/patronictl /usr/local/bin/pctl

# Environment variables for ease of use
ENV PATRONICTL_CONFIG_FILE=/etc/patroni/patroni.yml
ENV ETCDCTL_ENDPOINTS=http://etcd:2379
ENV ETCDCTL_API=3

# Create directories for Patroni config and Postgres data
RUN mkdir -p /etc/patroni /data/patroni && \
    chown -R postgres:postgres /etc/patroni /data/patroni

# Copy default configurations or scripts if necessary
# We will mount these dynamically, but setup user permissions
USER postgres

# Expose Patroni REST API and PostgreSQL
EXPOSE 8008 5432

CMD ["bash", "-c", "chmod 700 /data/patroni && exec patroni /etc/patroni/patroni.yml"]
