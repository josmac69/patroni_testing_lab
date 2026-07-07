FROM postgres:16

# Install Python, pip, and utilities
RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-venv \
    python3-dev \
    curl \
    iputils-ping \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni and its dependencies globally
# --break-system-packages is required for Debian Bookworm PEP 668 compliance
RUN pip3 install --break-system-packages "patroni[etcd3]" psycopg2-binary

# Create directories for Patroni config and Postgres data
RUN mkdir -p /etc/patroni /data/patroni && \
    chown -R postgres:postgres /etc/patroni /data/patroni

# Copy default configurations or scripts if necessary
# We will mount these dynamically, but setup user permissions
USER postgres

# Expose Patroni REST API and PostgreSQL
EXPOSE 8008 5432

CMD ["bash", "-c", "chmod 700 /data/patroni && exec patroni /etc/patroni/patroni.yml"]
