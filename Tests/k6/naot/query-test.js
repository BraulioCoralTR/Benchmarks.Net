import http from "k6/http";
import { check } from "k6";
// import { randomItem } from 'k6/experimental/collections'; // Removed import

// Base URL of your application
const BASE_URL = "http://localhost:8081"; // Adjust if your app runs on a different port/host

const NUM_SETUP_KEYS = 100; // Number of keys to pre-populate for querying

// --- Setup Function --- Runs once before the test
export function setup() {
  console.log(`INFO: Setting up ${NUM_SETUP_KEYS} keys for query test...`);
  const keys = [];
  const setupParams = {
    headers: { "Content-Type": "application/json" },
    // Add a timeout specific to setup? k6 default is 60s
    // timeout: '120s',
  };

  for (let i = 0; i < NUM_SETUP_KEYS; i++) {
    const key = `query-test-key-${i}`;
    const value = { data: `Setup data for ${key}`, index: i };
    const payload = JSON.stringify({ Key: key, Value: value });

    // Insert into Postgres
    const pgRes = http.post(`${BASE_URL}/postgres/cache`, payload, setupParams);
    if (pgRes.status !== 200) {
      console.error(
        `ERROR: Setup failed for Postgres key ${key}. Status: ${pgRes.status}, Body: ${pgRes.body}`
      );
      // Optionally fail the test if setup is critical
      // fail(`Setup failed for Postgres key ${key}`);
      continue; // Skip adding this key if insert failed
    }

    keys.push(key); // Add key to the list only if both inserts succeeded
    if ((i + 1) % 10 === 0) {
      console.log(
        `INFO: Setup progress... ${i + 1}/${NUM_SETUP_KEYS} keys inserted.`
      );
    }
  }

  if (keys.length !== NUM_SETUP_KEYS) {
    console.warn(
      `WARN: Setup only successfully inserted ${keys.length}/${NUM_SETUP_KEYS} keys.`
    );
  }
  if (keys.length === 0) {
    fail("Setup failed: No keys were successfully inserted.");
  }

  console.log(
    `INFO: Setup complete. ${keys.length} keys available for querying.`
  );
  return { keys }; // Return the list of keys
}

// --- Configuration for the main test stage ---
export const options = {
  vus: 80,
  iterations: 100000,
  thresholds: {
    "http_req_duration{endpoint:postgres_get}": ["p(95)<300"],
    "http_req_failed{endpoint:postgres_get}": ["rate<0.01"],
    "checks{endpoint:postgres_get}": ["rate>0.99"],
  },
  // If setup fails, don't run the main iterations
  setupTimeout: "120s", // Allow more time for setup if needed
};

// --- Default Function --- Runs concurrently by VUs after setup
export default function (data) {
  // Receives data returned from setup()
  // Randomly select a key from the list created during setup using Math.random()
  const randomIndex = Math.floor(Math.random() * data.keys.length);
  const key = data.keys[randomIndex];

  const params = {
    headers: {
      Accept: "application/json",
    },
  };

  // --- Test Postgres Get ---
  const postgresRes = http.get(`${BASE_URL}/postgres/cache/${key}`, {
    ...params,
    tags: { endpoint: "postgres_get" },
  });
    check(
        postgresRes,
        {
            "Postgres: get status is 200": (r) => r.status === 200,
            "Postgres: get response has valid status": (r) => r.status >= 200 && r.status < 300,
            "Postgres: get response is valid JSON": (r) => {
                if (r.status !== 200) {
                    console.error(`Postgres non-200 status ${r.status} for key ${key}: ${r.body}`);
                    return false; // Don't try to parse JSON for non-200 responses
                }
                try {
                    const jsonData = r.json();
                    return jsonData !== null && typeof jsonData === "object";
                } catch (e) {
                    console.error(`Postgres invalid JSON for key ${key} (status ${r.status}): ${r.body}`);
                    return false;
                }
            },
        },
        { endpoint: "postgres_get" }
    );
}

// --- Teardown Function --- Runs once after the test (optional)
export function teardown(data) {
  console.log(
    `INFO: Query test finished. Tested with ${data.keys.length} keys.`
  );
  http.del(`${BASE_URL}/postgres/cache`);
  console.log('INFO: Teardown cleanup finished.');
}
