import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter } from 'k6/metrics';

const errorRate = new Rate('errors');
const rateLimited = new Counter('rate_limited');
const BASE = __ENV.BASE_URL || 'http://192.168.100.31';

export const options = {
  stages: [
    { duration: '15s', target: 10  },   // warm up
    { duration: '30s', target: 500 },   // spike — triggers NGINX rate limiting
    { duration: '1m',  target: 500 },   // hold
    { duration: '30s', target: 10  },   // wind down
    { duration: '15s', target: 0   },   // cool off
  ],
  thresholds: {
    // We expect 429s during the spike — this just tracks error rate for non-429 failures
    errors: ['rate<0.05'],
  },
};

export default function () {
  const res = http.get(`${BASE}/api/products?category=electronics&limit=18`);

  if (res.status === 429) {
    rateLimited.add(1);
    return;
  }

  const ok = check(res, { 'products 200': (r) => r.status === 200 });
  errorRate.add(!ok);
}
