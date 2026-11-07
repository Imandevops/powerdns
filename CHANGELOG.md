# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-23

### Added
- 3-node PowerDNS cluster with full high-availability setup
- `etcd` cluster (3 nodes) for Patroni coordination
- `Patroni` + PostgreSQL with automatic leader election and failover
- `HAProxy` per node for PostgreSQL read/write load balancing
- `PowerDNS Authoritative` server on each node (port 5300)
- `PowerDNS Recursor` on each node (port 5301)
- `dnsdist` on each node (port 5454) with auth zone routing and recursive fallback
- `PowerAdmin` web UI for DNS zone management
- Cross-node failover in dnsdist: if local auth/recursor is down, queries are automatically routed to other nodes (order-based `firstAvailable` policy)
- Database bootstrap script (`initdb/00-bootstrap.sh`) to initialize PowerDNS and PowerAdmin schemas with correct permissions
- Cluster health test script (`test.sh`) covering port reachability, authoritative DNS, recursive DNS, dnsdist routing, and cross-node backend checks
- `setACL({"0.0.0.0/0", "::/0"})` in dnsdist config to allow queries through Docker NAT

### Fixed
- dnsdist config not loading due to file permission issues — documented in README and troubleshooting section
- dnsdist listening only on `127.0.0.1` instead of `0.0.0.0` (caused by config not being read)
- Recursor webserver port mismatch (`8082` → `8083`) between `recursor.conf` and `compose.yml`

### Changed
- dnsdist server definitions now use `AUTH_HOST`, `RECURSOR_HOST`, `REMOTE1_IP`, `REMOTE2_IP` environment variables instead of hardcoded hostnames, enabling a shared parameterized config across all nodes
- Exposed authoritative DNS port (5300:53) on node-1 (was missing, required for cross-node failover)
- Exposed recursor DNS port (5301:53) on node-1 (was missing, required for cross-node failover)
