-- Run as postgres superuser: psql -U postgres -f seed.sql

CREATE DATABASE demo;
\c demo

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE USER appuser WITH PASSWORD 'apppassword';
GRANT ALL PRIVILEGES ON DATABASE demo TO appuser;

\c demo

CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL,
  price       NUMERIC(10,2) NOT NULL,
  stock       INT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE orders (
  id          SERIAL PRIMARY KEY,
  product_id  INT NOT NULL REFERENCES products(id),
  quantity    INT NOT NULL,
  total       NUMERIC(10,2) NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- Seed 1,000,000 products
-- No index on category yet — intentional for the slow query demo
INSERT INTO products (name, category, price, stock)
SELECT
  'Product ' || i,
  (ARRAY['electronics','clothing','books','home','sports'])[1 + (random() * 4)::int % 5],
  round((random() * 990 + 10)::numeric, 2),
  (random() * 500)::int
FROM generate_series(1, 1000000) AS s(i);

-- Seed 10,000 historical orders spread over the last 30 days
INSERT INTO orders (product_id, quantity, total, created_at)
SELECT
  (random() * 999999 + 1)::int,
  (random() * 4 + 1)::int,
  round((random() * 500 + 5)::numeric, 2),
  now() - (random() * interval '30 days')
FROM generate_series(1, 10000);

ANALYZE products;
ANALYZE orders;

GRANT ALL PRIVILEGES ON TABLE products, orders TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
