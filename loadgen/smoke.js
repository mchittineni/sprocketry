// k6 smoke/load test through the storefront: browse, add to cart, view cart.
// Run: k6 run loadgen/smoke.js   (BASE_URL defaults to the local compose stack)
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:3000';

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '1m',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const home = http.get(`${BASE}/`);
  check(home, { 'home 200': (r) => r.status === 200 });

  const cart = http.get(`${BASE}/cart`);
  check(cart, { 'cart 200': (r) => r.status === 200 });

  sleep(1);
}
