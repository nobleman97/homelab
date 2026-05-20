import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');
const BASE = __ENV.BASE_URL || 'http://192.168.100.31';
const CATEGORIES = ['electronics', 'clothing', 'books', 'home', 'sports'];

export const options = {
  vus: 50,
  duration: '5m',
  thresholds: {
    http_req_duration: ['p(95)<500'],
    errors: ['rate<0.01'],
  },
};

export default function () {
  const roll = Math.random();

  if (roll < 0.70) {
    // 70% — browse products (random category filter)
    const category = CATEGORIES[Math.floor(Math.random() * CATEGORIES.length)];
    const page = Math.ceil(Math.random() * 5);
    const res = http.get(`${BASE}/api/products?category=${category}&page=${page}&limit=18`);
    const ok = check(res, { 'products 200': (r) => r.status === 200 });
    errorRate.add(!ok);

  } else if (roll < 0.90) {
    // 20% — place an order
    const productId = Math.floor(Math.random() * 999999) + 1;
    const res = http.post(
      `${BASE}/api/orders`,
      JSON.stringify({ product_id: productId, quantity: Math.ceil(Math.random() * 3) }),
      { headers: { 'Content-Type': 'application/json' } },
    );
    // 404 (product not found) and 409 (out of stock) are expected — not errors
    const ok = check(res, { 'order accepted': (r) => [201, 404, 409].includes(r.status) });
    errorRate.add(!ok);

  } else {
    // 10% — fetch stats
    const res = http.get(`${BASE}/api/stats`);
    const ok = check(res, { 'stats 200': (r) => r.status === 200 });
    errorRate.add(!ok);
  }

  sleep(0.5 + Math.random());
}
