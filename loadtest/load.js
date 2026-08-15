// Load test for the booklog service.
//
// The point of this script is to answer one question the first run could not:
// when p95 goes to 10 seconds, is the bottleneck CPU or the database?
//
// To reproduce the original behaviour for comparison:
//
//     k6 run -e BASE_URL=... -e MEASURE_AUTH=true loadtest/load.js
//
// Usage:
//
//     $env:BASE_URL = terraform output -raw alb_url
//     k6 run -e BASE_URL=$env:BASE_URL loadtest/load.js
//
// Useful knobs: PEAK_VUS, RAMP, HOLD, USERS, SEED_BOOKS.

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { randomSeed } from 'k6';

// configuration

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
const PEAK_VUS = parseInt(__ENV.PEAK_VUS || '100', 10);
const RAMP = __ENV.RAMP || '3m';
const HOLD = __ENV.HOLD || '4m';
const USERS = parseInt(__ENV.USERS || '25', 10);
const SEED_BOOKS = parseInt(__ENV.SEED_BOOKS || '12', 10);
const MEASURE_AUTH = (__ENV.MEASURE_AUTH || 'false') === 'true';
const PASSWORD = 'loadtest-password-123';

// metrics
//
// Named to match the first run so the numbers are directly comparable.

const latencyLibrary = new Trend('latency_library', true);
const latencyStats = new Trend('latency_stats', true);
const latencyWrite = new Trend('latency_write', true);
const latencyRegister = new Trend('latency_register', true);
const latencyLogin = new Trend('latency_login', true);

// Pool exhaustion and query timeouts surface as 500s with a recognisable
// body. Counting them separately is what distinguishes "the database is
// saturated" from "the application has a bug".
const dbConnectionErrors = new Counter('db_connection_errors');
const requestErrors = new Rate('request_errors');

// scenario
//
// ramping-vus, not constant-arrival-rate. Under a closed model a VU waits for
// its response before sending the next request, so a slow server naturally
// throttles the offered load - which is why the first run reached only 63 of
// 100 VUs. That is informative in itself: it means iteration duration, not
// k6, was the limit.

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: RAMP, target: PEAK_VUS },
        { duration: HOLD, target: PEAK_VUS },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },

  // Thresholds are assertions, not decoration. A crossed threshold exits
  // non-zero, which is what lets this run in CI later.
  thresholds: {
    'latency_library': ['p(95)<1000'],
    'latency_stats': ['p(95)<1500'],
    'latency_write': ['p(95)<1500'],
    'request_errors': ['rate<0.01'],
    'db_connection_errors': ['count<1'],
    'http_req_failed': ['rate<0.01'],
  },

  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// helpers

function authHeaders(token) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
  };
}

// Classify a failure rather than just counting it. The distinction between
// "connection pool exhausted" and "unhandled exception" is the whole point of
// running the test.
function classify(res) {
  const ok = res.status >= 200 && res.status < 400;
  requestErrors.add(!ok);

  if (!ok && res.status >= 500) {
    const body = (res.body || '').toLowerCase();
    if (
      body.includes('pool') ||
      body.includes('connection') ||
      body.includes('timeout') ||
      res.status === 503 ||
      res.status === 504
    ) {
      dbConnectionErrors.add(1);
    }
  }
  return ok;
}

// setup: runs once, on one machine, before any load
//
// Everything expensive and unrepresentative happens here - argon2 hashing and
// seeding library rows. None of it lands in the measured window.

export function setup() {
  randomSeed(42);

  const health = http.get(`${BASE_URL}/healthz`);
  if (health.status !== 200) {
    fail(`service not healthy at ${BASE_URL}/healthz (status ${health.status})`);
  }

  const ready = http.get(`${BASE_URL}/readyz`);
  if (ready.status !== 200) {
    fail(`service not ready - database unreachable (status ${ready.status})`);
  }

  const run = Date.now();
  const accounts = [];

  for (let i = 0; i < USERS; i++) {
    const email = `load-${run}-${i}@example.com`;

    const reg = http.post(
      `${BASE_URL}/register`,
      JSON.stringify({ email, password: PASSWORD }),
      { headers: { 'Content-Type': 'application/json' } }
    );
    if (reg.status !== 201) {
      fail(`setup: register failed for ${email} (${reg.status}) ${reg.body}`);
    }

    const login = http.post(
      `${BASE_URL}/login`,
      JSON.stringify({ email, password: PASSWORD }),
      { headers: { 'Content-Type': 'application/json' } }
    );
    if (login.status !== 200) {
      fail(`setup: login failed for ${email} (${login.status})`);
    }

    const token = login.json('access_token');
    const entryIds = [];

    // Seed a library so /stats and /library have something to aggregate. An
    // empty library makes every query trivially fast and the test worthless.
    for (let b = 0; b < SEED_BOOKS; b++) {
      const add = http.post(
        `${BASE_URL}/library`,
        JSON.stringify({
          ol_work_key: `/works/OL${1000 + b}W`,
          title: `Seed Book ${b}`,
          authors: [`Author ${b % 5}`],
          first_publish_year: 1950 + b,
          page_count: 180 + b * 37,
          format: ['paper', 'ebook', 'audio'][b % 3],
        }),
        authHeaders(token)
      );
      if (add.status === 201) {
        entryIds.push(add.json('id'));
      }
    }

    accounts.push({ email, token, entryIds });
  }

  console.log(
    `setup complete: ${accounts.length} users, ~${SEED_BOOKS} books each. ` +
      `Registration is OUTSIDE the measured window.`
  );

  return { accounts, run };
}

// the measured loop
//
// Roughly 4 reads per write, which is the shape of real traffic for a
// tracker: people look at their shelf far more often than they update it.

export default function (data) {
  const account = data.accounts[(__VU - 1) % data.accounts.length];
  const headers = authHeaders(account.token);

  // Optional: pay the argon2 cost inside the loop, reproducing the original
  // confounded test. Off by default.
  if (MEASURE_AUTH) {
    const email = `churn-${data.run}-${__VU}-${__ITER}@example.com`;
    const reg = http.post(
      `${BASE_URL}/register`,
      JSON.stringify({ email, password: PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'register' } }
    );
    latencyRegister.add(reg.timings.duration);
    classify(reg);

    const login = http.post(
      `${BASE_URL}/login`,
      JSON.stringify({ email, password: PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } }
    );
    latencyLogin.add(login.timings.duration);
    classify(login);
  }

  // --- read: the shelf ---
  const list = http.get(`${BASE_URL}/library?limit=50`, {
    ...headers,
    tags: { name: 'GET /library' },
  });
  latencyLibrary.add(list.timings.duration);
  check(list, { 'library 200': (r) => r.status === 200 });
  classify(list);

  sleep(0.3);

  // --- read: filtered shelf, a different query plan ---
  const filtered = http.get(`${BASE_URL}/library?status=reading&limit=50`, {
    ...headers,
    tags: { name: 'GET /library?status' },
  });
  latencyLibrary.add(filtered.timings.duration);
  classify(filtered);

  sleep(0.3);

  // --- read: the expensive one ---
  // /stats is the aggregate query. If anything is going to fall over under
  // concurrency it is this, which is why it gets its own metric.
  const stats = http.get(`${BASE_URL}/stats`, {
    ...headers,
    tags: { name: 'GET /stats' },
  });
  latencyStats.add(stats.timings.duration);
  check(stats, { 'stats 200': (r) => r.status === 200 });
  classify(stats);

  sleep(0.5);

  // --- write: progress on an existing entry ---
  // A PATCH rather than a POST, because it is the write a real user actually
  // repeats. Creating a book every iteration would grow the table without
  // bound and make late iterations slower than early ones for reasons that
  // have nothing to do with concurrency.
  if (account.entryIds.length > 0) {
    const entryId =
      account.entryIds[Math.floor(Math.random() * account.entryIds.length)];
    const page = 1 + Math.floor(Math.random() * 150);

    const patch = http.patch(
      `${BASE_URL}/library/${entryId}/progress`,
      JSON.stringify({ page }),
      { ...headers, tags: { name: 'PATCH /library/:id/progress' } }
    );
    latencyWrite.add(patch.timings.duration);
    check(patch, { 'progress 200': (r) => r.status === 200 });
    classify(patch);
  }

  sleep(1);
}

// teardown

export function teardown(data) {
  console.log(
    `teardown: ${data.accounts.length} load-test users left in the database ` +
      `(emails prefixed load-${data.run}-). Harmless in dev; delete before ` +
      `taking any screenshots of /stats.`
  );
}
