-- Scripture study agent — Phase 1 schema
-- Postgres 16 + pgvector. Verse-level embeddings for semantic search.

CREATE EXTENSION IF NOT EXISTS vector;

-- Idempotent: setup.sh re-runs safely.
DROP TABLE IF EXISTS verses;
DROP TABLE IF EXISTS works;

CREATE TABLE works (
    id      serial PRIMARY KEY,
    code    text UNIQUE NOT NULL,   -- 'bofm', 'ot', 'nt', 'dc', 'pgp'
    title   text NOT NULL
);

CREATE TABLE verses (
    id         serial PRIMARY KEY,
    work_id    integer NOT NULL REFERENCES works(id),
    book       text NOT NULL,       -- '1 Nephi'
    chapter    integer NOT NULL,
    verse      integer NOT NULL,
    reference  text NOT NULL,       -- '1 Nephi 1:1' (display + dedup key)
    text       text NOT NULL,
    text_tsv   tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    embedding  vector(768),         -- nomic-embed-text dimensionality
    UNIQUE (work_id, book, chapter, verse)
);

CREATE INDEX verses_embedding_hnsw
    ON verses USING hnsw (embedding vector_cosine_ops);
CREATE INDEX verses_text_tsv_gin
    ON verses USING gin (text_tsv);
CREATE INDEX verses_reference_idx
    ON verses (reference);
