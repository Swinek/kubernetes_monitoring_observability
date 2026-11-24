import http from 'k6/http';
import { check } from 'k6';

const SCENARIO = __ENV.SCENARIO || 'cpu';
const BASE_URL = __ENV.BASE_URL || 'http://demo-app.demo.svc.cluster.local';
const RATE = Number(__ENV.RATE || (SCENARIO === 'cpu' ? 15 : 2));
const DURATION = __ENV.DURATION || '4m';
const CPU_MS = Number(__ENV.CPU_MS || 100);
const MEM_MB = Number(__ENV.MEM_MB || 20);
const MEM_SECONDS = Number(__ENV.MEM_SECONDS || 15);

export const options = {
  noConnectionReuse: true,
  scenarios: {
    load: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 400,
      stages: [
        { target: RATE, duration: '1m' },
        { target: RATE, duration: DURATION },
      ],
    },
  },
};

export default function () {
  const url = SCENARIO === 'memory'
    ? `${BASE_URL}/load/memory?mb=${MEM_MB}&seconds=${MEM_SECONDS}`
    : `${BASE_URL}/load/cpu?ms=${CPU_MS}`;
  const res = http.get(url, { timeout: '60s', tags: { scenario: SCENARIO } });
  check(res, { 'status 200': (r) => r.status === 200 });
}
