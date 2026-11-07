#!/bin/bash
set -euo pipefail

# PowerAdmin on PostgreSQL uses a single database (no separate PDNS DB).
# Combined DB name is PA_DB_NAME. PDNS tables are owned by PDNS_DB_USER;
# PowerAdmin tables by PA_DB_USER; PA user is granted DML on PDNS tables.

export PGPASSWORD="${POSTGRES_PASSWORD}"
PGSUPER=( -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" )
COMBINED_DB="${PA_DB_NAME}"

psql "${PGSUPER[@]}" \
  -v "pdns_user=${PDNS_DB_USER}" \
  -v "pdns_pw=${PDNS_DB_PASSWORD}" \
  -v "pa_user=${PA_DB_USER}" \
  -v "pa_pw=${PA_DB_PASSWORD}" \
  -v "combined_db=${COMBINED_DB}" <<'SQL'
CREATE USER :"pdns_user" WITH PASSWORD :'pdns_pw';
CREATE USER :"pa_user" WITH PASSWORD :'pa_pw';
CREATE DATABASE :"combined_db" OWNER :"pa_user";
SQL

psql "${PGSUPER[@]}" \
  -v "pdns_user=${PDNS_DB_USER}" \
  -v "combined_db=${COMBINED_DB}" <<'SQL'
GRANT CONNECT ON DATABASE :"combined_db" TO :"pdns_user";
SQL

export PGPASSWORD="${PA_DB_PASSWORD}"
psql -v ON_ERROR_STOP=1 --username "${PA_DB_USER}" -d "${COMBINED_DB}" \
  -f /docker-entrypoint-initdb.d/schemas/poweradmin-schema.pgsql

export PGPASSWORD="${POSTGRES_PASSWORD}"
psql "${PGSUPER[@]}" -d "${COMBINED_DB}" \
  -v "pdns_user=${PDNS_DB_USER}" <<'SQL'
GRANT CREATE ON SCHEMA public TO :"pdns_user";
SQL

export PGPASSWORD="${PDNS_DB_PASSWORD}"
psql -v ON_ERROR_STOP=1 --username "${PDNS_DB_USER}" -d "${COMBINED_DB}" \
  -f /docker-entrypoint-initdb.d/schemas/pdns-schema.pgsql

export PGPASSWORD="${POSTGRES_PASSWORD}"
psql "${PGSUPER[@]}" -d "${COMBINED_DB}" \
  -v "pdns_user=${PDNS_DB_USER}" \
  -v "pa_user=${PA_DB_USER}" <<'SQL'
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"pa_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"pa_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"pdns_user" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"pa_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"pdns_user" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"pa_user";
SQL

# Create the initial authoritative zone with SOA and NS records
export PGPASSWORD="${PDNS_DB_PASSWORD}"
psql -v ON_ERROR_STOP=1 --username "${PDNS_DB_USER}" -d "${COMBINED_DB}" \
  -v "zone=${PDNS_AUTH_ZONE}" \
  -v "ns1=${DNS_NS1}" \
  -v "ns2=${DNS_NS2}" \
  -v "hostmaster=${DNS_HOSTMASTER}" <<'SQL'
INSERT INTO domains (name, type) VALUES (:'zone', 'NATIVE');

INSERT INTO records (domain_id, name, type, content, ttl)
SELECT id, :'zone', 'SOA',
  :'ns1' || ' ' || :'hostmaster' || ' 1 10800 3600 604800 3600',
  3600
FROM domains WHERE name = :'zone';

INSERT INTO records (domain_id, name, type, content, ttl)
SELECT id, :'zone', 'NS', :'ns1', 3600
FROM domains WHERE name = :'zone';

INSERT INTO records (domain_id, name, type, content, ttl)
SELECT id, :'zone', 'NS', :'ns2', 3600
FROM domains WHERE name = :'zone';
SQL
