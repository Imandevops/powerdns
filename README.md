# PowerDNS Cluster Setup

A 3-node high-availability PowerDNS cluster with automatic failover, backed by a Patroni/PostgreSQL cluster and coordinated by etcd.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │               DNS Clients                   │
                    └──────────┬──────────┬──────────┬────────────┘
                               │          │          │
                        :5454  │   :5454  │   :5454  │
                    ┌──────────▼──┐ ┌─────▼──────┐ ┌▼────────────┐
                    │  dnsdist1   │ │  dnsdist2  │ │  dnsdist3   │
                    │  (node-1)   │ │  (node-2)  │ │  (node-3)   │
                    └──────┬──┬───┘ └─────┬──┬───┘ └──┬──┬───────┘
                           │  │           │  │        │  │
              auth zone ───┘  └─ recurse  │  │        │  │
                                          │  │        │  │
         ┌────────────────────────────────┘  │        │  │
         │  Authoritative Servers (:5300)    │        │  │
         │  ┌─────────────┐ ┌─────────────┐ │┌────────┴──┴──────┐
         │  │authoritative│ │authoritative│ ││ authoritative3   │
         │  │    1        │ │    2        │ ││    (node-3)      │
         │  └──────┬──────┘ └──────┬──────┘ │└────────┬─────────┘
         │         │               │        │         │
         │  Recursor Servers (:5301)        │         │
         │  ┌─────────────┐ ┌─────────────┐ │┌────────┴─────┐
         └▶│  recursor1  │ │  recursor2  │ ││  recursor3   │
            └─────────────┘ └─────────────┘ │└──────────────┘
                                               │
         ┌─────────────────────────────────────┘
         │  PostgreSQL Cluster (Patroni + etcd)
         │  ┌──────────┐  ┌──────────┐  ┌──────────┐
         └▶│ patroni1 │  │ patroni2 │  │ patroni3 │
            │  + etcd1 │  │  + etcd2 │  │  + etcd3 │
            └──────────┘  └──────────┘  └──────────┘
```

### Components per Node

| Service | Port (host) | Description |
|---------|-------------|-------------|
| etcd | 2379, 2380 | Distributed coordination for Patroni |
| patroni | 5432, 8008 | PostgreSQL with automatic failover |
| haproxy | 5000 | Load balancer for PostgreSQL reads/writes |
| authoritative | 5300, 8081 | PowerDNS authoritative server |
| recursor | 5301, 8082 | PowerDNS recursive resolver |
| dnsdist | 5454, 8084 | DNS load balancer and router |
| poweradmin | 80 | Web UI for managing DNS zones (node-1 only) |

### Failover Behavior

`dnsdist` on each node routes queries using `firstAvailable` policy with ordered backends:

| Priority | Backend | Port |
|----------|---------|------|
| 1 (primary) | Local node auth / recursor | 53 (internal Docker network) |
| 2 (fallback) | Remote node 1 auth / recursor | 5300 / 5301 |
| 3 (fallback) | Remote node 2 auth / recursor | 5300 / 5301 |

If the local server fails health checks, dnsdist automatically routes to the next available backend — no restart required.

## Prerequisites

- Docker >= 24
- Docker Compose >= 2.20
- `dig` and `nc` installed on the host (for testing)
- Ports 5300, 5301, 5454, 8081, 8082, 8084 open between nodes

## Directory Structure

```
.
├── node-1/
│   ├── compose.yml
│   ├── .env
│   ├── dnsdist/dnsdist.conf
│   ├── pdns/pdns.conf
│   ├── recursor/recursor.conf
│   └── initdb/
│       ├── 00-bootstrap.sh
│       └── schemas/
├── node-2/            (same structure)
├── node-3/            (same structure)
├── test.sh            (cluster health test)
├── CHANGELOG.md
└── README.md
```

## Configuration

Each node has a `.env` file with the following variables:

```env
# Node identity
NODE_IP=<this-node-ip>
NODE1_IP=<node-1-ip>
NODE2_IP=<node-2-ip>
NODE3_IP=<node-3-ip>

# Patroni
PATRONI_RESTAPI_USERNAME=
PATRONI_RESTAPI_PASSWORD=
PATRONI_SUPERUSER_USERNAME=postgres
PATRONI_SUPERUSER_PASSWORD=
PATRONI_REPLICATION_USERNAME=replicator
PATRONI_REPLICATION_PASSWORD=
PATRONI_ADMIN_PASSWORD=

# PostgreSQL
POSTGRES_USER=postgres
POSTGRES_PASSWORD=

# PowerDNS
PDNS_API_KEY=
PDNS_AUTH_ZONE=example.com.
DNS_NS1=ns1.example.com
DNS_NS2=ns2.example.com
DNS_HOSTMASTER=hostmaster.example.com
PDNS_DB_USER=pdns
PDNS_DB_PASSWORD=

# Recursor
PDNS_RECURSOR_API_KEY=

# dnsdist
DNSDIST_API_KEY=
DNSDIST_AUTH_ZONE=example.com.

# PowerAdmin
PA_ADMIN_PASSWORD=
PA_DB_NAME=poweradmin
PA_DB_USER=poweradmin
PA_DB_PASSWORD=

# Docker
RESTART_POLICY=unless-stopped
```

## Deployment

### First-time setup (run in order)

**Node 1 — bootstrap the database cluster:**
```bash
scp -rp node-1/ user@node1:/opt/pdns-cluster/
ssh user@node1 "cd /opt/pdns-cluster && docker compose -f node-1/compose.yml up -d etcd1 patroni1 haproxy1"
```

**Nodes 2 & 3 — join the cluster:**
```bash
scp -rp node-2/ user@node2:/opt/pdns-cluster/
scp -rp node-3/ user@node3:/opt/pdns-cluster/
ssh user@node2 "cd /opt/pdns-cluster && docker compose -f node-2/compose.yml up -d etcd2 patroni2 haproxy2"
ssh user@node3 "cd /opt/pdns-cluster && docker compose -f node-3/compose.yml up -d etcd3 patroni3 haproxy3"
```

**Start DNS services on all nodes:**
```bash
for node in 1 2 3; do
  ssh user@node${node} "cd /opt/pdns-cluster && docker compose -f node-${node}/compose.yml up -d"
done
```

### Transfer files with permissions preserved
```bash
scp -rp node-1/ user@node1:/opt/pdns-cluster/
```

### Restart a single service
```bash
docker compose -f node-1/compose.yml restart dnsdist1
```

## Testing

Run the full cluster health test from any machine that can reach all three nodes:

```bash
./test.sh
```

The script covers:
- **Port reachability** — authoritative (:5300), recursor (:5301), dnsdist (:5454) on all nodes
- **Authoritative DNS** — SOA, NS, and A record queries direct to each node
- **Recursive DNS** — external resolution through each recursor
- **dnsdist routing** — auth zone and recursive routing through each dnsdist
- **Cross-node backends** — verifies fallback backends are reachable between nodes

## Web Interfaces

| Interface | URL | Description |
|-----------|-----|-------------|
| PowerAdmin | `http://node1:80` | DNS zone management |
| dnsdist API | `http://node1:8084` | dnsdist statistics |
| Recursor API | `http://node1:8082` | Recursor statistics |
| PowerDNS API | `http://node1:8081` | Authoritative server API |
| Patroni REST | `http://node1:8008` | Cluster status |

## Troubleshooting

**dnsdist not loading config:**
Check that config file permissions allow the container user to read it:
```bash
chmod 644 node-*/dnsdist/dnsdist.conf
```

**Queries timing out from outside:**
Ensure `setACL({"0.0.0.0/0", "::/0"})` is present in `dnsdist.conf` — without it, dnsdist silently drops queries that arrive via Docker NAT (source IP is the bridge gateway, not 127.0.0.1).

**Patroni not forming a cluster:**
Verify all three etcd nodes are reachable and the `ETCD_INITIAL_CLUSTER` env var has the correct IPs.
