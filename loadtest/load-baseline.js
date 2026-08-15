// Load test for the booklog API.
//
//   k6 run -e BASE_URL=http://your-alb-dns loadtest/load.js
//
// Ramps to 100 virtual users over 8 minutes, hammering the two read endpoints
// that matter: /library (indexed lookup, paginated) and /stats (four queries,
// one of them a window function).

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

const BASE = __ENV.BASE_URL;
if (!BASE) {
  throw new Error("Set BASE_URL, e.g. -e BASE_URL=http://my-alb.amazonaws.com");
}

// Custom metrics so the summary separates the cheap endpoint from the
// expensive one.
const statsLatency = new Trend("latency_stats", true);
const libraryLatency = new Trend("latency_library", true);
const writeLatency = new Trend("latency_write", true);
const errors = new Rate("errors");
const dbErrors = new Counter("db_connection_errors");

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "1m", target: 10 },   
        { duration: "2m", target: 30 },
        { duration: "2m", target: 60 },
        { duration: "2m", target: 100 },  
        { duration: "1m", target: 0 },    
      ],
      gracefulRampDown: "30s",
    },
  },

  // Thresholds fail the run rather than just reporting. Treat a failed
  // threshold as the finding.
  thresholds: {
    "http_req_failed": ["rate<0.05"],
    "latency_library": ["p(95)<500"],
    "latency_stats": ["p(95)<1000"],
  },

  // Don't let a slow response pile up behind a stuck connection.
  noConnectionReuse: false,
  discardResponseBodies: false,
};

const BOOKS = [
  { ol_work_key: "OL893415W", title: "Dune", authors: ["Frank Herbert"], page_count: 604 },
  { ol_work_key: "OL27448W", title: "The Lord of the Rings", authors: ["J. R. R. Tolkien"], page_count: 1178 },
  { ol_work_key: "OL262758W", title: "Neuromancer", authors: ["William Gibson"], page_count: 271 },
  { ol_work_key: "OL8193422W", title: "Piranesi", authors: ["Susanna Clarke"], page_count: 245 },
  { ol_work_key: "OL1794792W", title: "Snow Crash", authors: ["Neal Stephenson"], page_count: 440 },
  { ol_work_key: "OL20600W", title: "Solaris", authors: ["Stanislaw Lem"], page_count: 204 },
];

const JSON_HEADERS = { "Content-Type": "application/json" };

export function setup() {
  const r = http.get(`${BASE}/healthz`);
  check(r, { "service is up before test starts": (res) => res.status === 200 });
  if (r.status !== 200) {
    throw new Error(`/healthz returned ${r.status} - is the service deployed?`);
  }
  return { startedAt: new Date().toISOString() };
}

export default function () {
  const email = `load-${__VU}-${Date.now()}@example.com`;
  const password = "correcthorse1";

  // --- register + login once per iteration start ---
  let token;
  group("auth", () => {
    const reg = http.post(
      `${BASE}/register`,
      JSON.stringify({ email, password }),
      { headers: JSON_HEADERS, tags: { endpoint: "register" } }
    );

    if (reg.status !== 201) {
      errors.add(1);

      if (reg.status === 500 || reg.status === 503) dbErrors.add(1);
      return;
    }

    const login = http.post(
      `${BASE}/login`,
      JSON.stringify({ email, password }),
      { headers: JSON_HEADERS, tags: { endpoint: "login" } }
    );

    if (login.status === 200) {
      token = login.json("access_token");
    } else {
      errors.add(1);
    }
  });

  if (!token) {
    sleep(1);
    return;
  }

  const auth = { ...JSON_HEADERS, Authorization: `Bearer ${token}` };

  // --- seed a small library so /stats has something to aggregate ---
  group("write", () => {
    for (const book of BOOKS.slice(0, 3)) {
      const res = http.post(`${BASE}/library`, JSON.stringify(book), {
        headers: auth,
        tags: { endpoint: "add_book" },
      });
      writeLatency.add(res.timings.duration);

      const ok = res.status === 201 || res.status === 409;
      check(res, { "add book ok": () => ok });
      if (!ok) {
        errors.add(1);
        if (res.status >= 500) dbErrors.add(1);
      }
    }
  });

  group("read", () => {
    // Cheap: indexed on (user_id, created_at), paginated.
    const list = http.get(`${BASE}/library?limit=50`, {
      headers: auth,
      tags: { endpoint: "list_library" },
    });
    libraryLatency.add(list.timings.duration);
    check(list, { "list 200": (r) => r.status === 200 });
    if (list.status !== 200) {
      errors.add(1);
      if (list.status >= 500) dbErrors.add(1);
    }

    // Filtered variant - exercises the (user_id, status) index.
    const filtered = http.get(`${BASE}/library?status=want_to_read`, {
      headers: auth,
      tags: { endpoint: "list_filtered" },
    });
    libraryLatency.add(filtered.timings.duration);
    check(filtered, { "filtered 200": (r) => r.status === 200 });


    const stats = http.get(`${BASE}/stats`, {
      headers: auth,
      tags: { endpoint: "stats" },
    });
    statsLatency.add(stats.timings.duration);
    check(stats, { "stats 200": (r) => r.status === 200 });
    if (stats.status !== 200) {
      errors.add(1);
      if (stats.status >= 500) dbErrors.add(1);
    }
  });


  sleep(Math.random() * 2 + 0.5);
}

export function teardown(data) {
  console.log(`started at ${data.startedAt}, finished at ${new Date().toISOString()}`);
}
