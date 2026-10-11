#!/usr/bin/env bash
# End-to-end repeatable rollout for scripture-study-agent.
# Idempotent: safe to re-run. Two modes:
#
#   ./setup.sh            # docker compose (postgres + ollama containers)
#   ./setup.sh --local    # native install on Ubuntu/Debian (installs what's missing)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:---compose}"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-scripture}"
APP_DB_URL="dbname=scriptures user=scripture password=${POSTGRES_PASSWORD} host=localhost"
SUPER_DB_URL="dbname=scriptures user=postgres password=${POSTGRES_PASSWORD} host=localhost"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
EMBED_MODEL="nomic-embed-text"

# Container runtime abstraction: prefer Podman (daemonless, rootless,
# no licensing strings attached), fall back to Docker. Both speak the
# same compose file.
compose() {
  if command -v podman >/dev/null && podman compose version >/dev/null 2>&1; then
    podman compose "$@"
  elif command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v podman-compose >/dev/null; then
    podman-compose "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose "$@"
  else
    echo "no container runtime found (need podman or docker with compose)" >&2
    return 1
  fi
}

# ollama CLI: host binary preferred; in compose mode without a host binary,
# run it inside the ollama container (./models is mounted at /models there).
ocli() {
  if command -v ollama >/dev/null 2>&1; then
    ollama "$@"
  elif [[ "$MODE" == "--compose" ]]; then
    compose exec -T ollama ollama "$@"
  else
    echo "ollama CLI not found and no container runtime active" >&2
    return 1
  fi
}

bootstrap_ubuntu() {
  # Make apt usable: drop dead mirrors that hang `apt-get update`.
  if grep -rl cogentco /etc/apt/sources.list.d/ 2>/dev/null | grep -q .; then
    grep -rl cogentco /etc/apt/sources.list.d/ | xargs sudo sed -i 's| http://mirror.cogentco.com/pub/linux/ubuntu||'
  fi
  local pkgs=()
  command -v psql >/dev/null || pkgs+=(postgresql-16 postgresql-16-pgvector)
  python3 -c "import psycopg" 2>/dev/null || pkgs+=(python3-psycopg)
  command -v ollama >/dev/null || pkgs+=(zstd)
  command -v curl >/dev/null || pkgs+=(curl)
  if ((${#pkgs[@]})); then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  fi
  # postgres cluster up (fresh VMs don't autostart it)
  if ! pg_lsclusters 2>/dev/null | grep -q "5432.*online"; then
    sudo pg_ctlcluster 16 main start 2>/dev/null || true
  fi
  # ollama installed but not running -> start it (needs proxy env for pulls)
  if command -v ollama >/dev/null && ! curl -sf -m 3 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    if ! pgrep -x ollama >/dev/null; then
      nohup ollama serve >/tmp/ollama.log 2>&1 &
      sleep 4
    fi
  fi
  # ollama missing entirely -> install from script (needs zstd, installed above)
  if ! command -v ollama >/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
    nohup ollama serve >/tmp/ollama.log 2>&1 &
    sleep 4
  fi
}

if [[ "$MODE" == "--compose" ]]; then
  # Data lives in ./data (bind mounts), which survives VM replacement.
  mkdir -p data/postgres data/ollama
  compose up -d
  echo "waiting for postgres..."
  until compose exec -T db pg_isready -U postgres -d scriptures >/dev/null 2>&1; do sleep 2; done
elif [[ "$MODE" == "--local" ]]; then
  bootstrap_ubuntu
else
  echo "unknown mode: $MODE (use --compose or --local)"; exit 1
fi

echo "== database + roles =="
# superuser password auth may not exist on fresh installs; use the postgres os user
if ! psql "$SUPER_DB_URL" -c "SELECT 1" >/dev/null 2>&1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -v pw="$POSTGRES_PASSWORD" <<'SQL'
ALTER USER postgres WITH PASSWORD :'pw';
SELECT 'CREATE DATABASE scriptures' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'scriptures')\gexec
CREATE EXTENSION IF NOT EXISTS vector;
-- NB: psql :'var' interpolation does NOT happen inside DO $$ blocks
-- (dollar-quoted string), so use top-level \gexec instead.
SELECT format('CREATE USER scripture WITH PASSWORD %L', :'pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scripture')\gexec
GRANT ALL PRIVILEGES ON DATABASE scriptures TO scripture;
SQL
else
  psql "$SUPER_DB_URL" -v ON_ERROR_STOP=1 -v pw="$POSTGRES_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SELECT format('CREATE USER scripture WITH PASSWORD %L', :'pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'scripture')\gexec
GRANT ALL PRIVILEGES ON DATABASE scriptures TO scripture;
SQL
fi

echo "== schema =="
psql "$SUPER_DB_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
psql "$SUPER_DB_URL" -v ON_ERROR_STOP=1 -c \
  "GRANT ALL ON ALL TABLES IN SCHEMA public TO scripture; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO scripture;"

echo "== corpus =="
mkdir -p corpus
if [[ ! -f corpus/bom-flat.json ]]; then
  curl -sSL -o corpus/bom-flat.json \
    https://raw.githubusercontent.com/bcbooks/scriptures-json/master/flat/book-of-mormon-flat.json
fi

echo "== ingest =="
python3 ingest/ingest_bom.py --corpus corpus/bom-flat.json --db "$APP_DB_URL" --schema db/schema.sql

echo "== embedding model =="
export OLLAMA_HOST
if ! ocli list 2>/dev/null | grep -q "$EMBED_MODEL"; then
  if ! ocli pull "$EMBED_MODEL" 2>/dev/null; then
    echo "registry pull failed, falling back to HuggingFace download"
    mkdir -p models
    if [[ ! -f models/nomic-embed-text-v1.5.f16.gguf ]]; then
      curl -sSL -o models/nomic-embed-text-v1.5.f16.gguf \
        https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.f16.gguf
    fi
    printf 'FROM ./nomic-embed-text-v1.5.f16.gguf\n' > models/Modelfile
    if command -v ollama >/dev/null 2>&1; then
      (cd models && ollama create "$EMBED_MODEL" -f Modelfile)
    else
      # compose mode without host CLI: create inside the container
      # (./models is mounted at /models, relative FROM resolves there)
      compose exec -T ollama ollama create "$EMBED_MODEL" -f /models/Modelfile
    fi
  fi
fi

echo "== embeddings =="
python3 ingest/embed.py --db "$APP_DB_URL" --batch 32

echo "== verify =="
python3 search/search.py --db "$APP_DB_URL" "verses about faith" --k 3
echo "rollout complete"
