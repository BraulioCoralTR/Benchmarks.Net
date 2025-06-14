import http from "k6/http";
import { check, sleep } from "k6";

// Base URL of your application
const BASE_URL = "http://localhost:8081"; // Adjust if your app runs on a different port/host

export const options = {
  vus: 80,
  iterations: 100000,
  thresholds: {
    "http_req_duration{endpoint:postgres_insert}": ["p(95)<300"], // 95% of requests should be below 500ms
    "http_req_failed{endpoint:postgres_insert}": ["rate<0.01"], // Error rate should be less than 1%
    "checks{endpoint:postgres_insert}": ["rate>0.99"], // Check success rate should be higher than 99%
  },
};

export default function () {
  // Generate a unique key based on VU ID and iteration number
  const key = `key-${__VU}-${__ITER}`;
  const value = {
    data: `some data for ${key}`,
    timestamp: new Date().toISOString(),
    vu: __VU,
    iter: __ITER,
  };
  const payload = JSON.stringify({ Key: key, Value: value });
  const params = {
    headers: {
      "Content-Type": "application/json",
    },
  };

  // --- Test Postgres Insert ---
  const postgresRes = http.post(`${BASE_URL}/postgres/cache`, payload, {
    ...params,
    tags: { endpoint: "postgres_insert" },
  });
  check(
    postgresRes,
    {
      "Postgres: insert status is 200": (r) => r.status === 200,
    },
    { endpoint: "postgres_insert" }
  );

  // Optional: Add a small sleep if needed, e.g., sleep(0.1);

}


// --- Teardown Function --- Runs once after the test (optional)
export function teardown() {
  console.log(
    `INFO: Insert test finished.`
  );
  http.del(`${BASE_URL}/postgres/cache`);
  console.log('INFO: Teardown cleanup finished.');
}