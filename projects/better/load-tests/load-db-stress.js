/**
 * DB stress test — before/after index demo.
 *
 * Run BEFORE adding the index:
 *   k6 run load-tests/load-db-stress.js
 *   → p95 should be > 1000ms (full seq scan on 1M rows)
 *
 * Then on postgres-01:
 *   psql -U appuser -d demo -c "
 *     CREATE INDEX CONCURRENTLY idx_products_category_created
 *     ON products (category, created_at DESC);
 *   "
 *
 * Run AFTER adding the index:
 *   k6 run load-tests/load-db-stress.js
 *   → p95 should drop to < 10ms
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const queryDuration = new Trend('query_duration', true);
const BASE = __ENV.BASE_URL || 'http://192.168.100.31';

export const options = {
  vus: 100,
  duration: '2m',
  thresholds: {
    errors: ['rate<0.01'],
  },
};

export default function () {
  const start = Date.now();
  const res = http.get(`${BASE}/api/products?category=electronics&limit=18&page=1`);
  queryDuration.add(Date.now() - start);

  const ok = check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(!ok);

  sleep(0.1);
}
