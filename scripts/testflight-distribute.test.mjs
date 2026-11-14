import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  addBuildToInternalGroups,
  createClient,
  findAppId,
  waitForProcessedBuild,
} from './testflight-distribute.mjs';

/** A fetch stand-in routing by method and path prefix; records every call. */
function fakeApi(routes) {
  const calls = [];
  const fetchImpl = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const path = url.replace('https://api.appstoreconnect.apple.com/v1', '');
    calls.push({ method, path, body: options.body ? JSON.parse(options.body) : undefined });
    const route = routes.find((candidate) => candidate.method === method && path.startsWith(candidate.path));
    if (!route) return new Response('not found', { status: 404 });
    const body = typeof route.body === 'function' ? route.body() : route.body;
    return body === null
      ? new Response(null, { status: 204 })
      : new Response(JSON.stringify(body), { status: route.status ?? 200 });
  };
  return { calls, request: createClient({ fetchImpl, tokenProvider: () => 'token' }) };
}

const build = (state) => ({ data: [{ id: 'build-1', attributes: { version: '5', processingState: state } }] });

test('finds the one app whose bundle ID matches exactly', async () => {
  const { request } = fakeApi([{ method: 'GET', path: '/apps?', body: { data: [{ id: 'app-1', attributes: { bundleId: 'example.app' } }] } }]);
  assert.equal(await findAppId(request, 'example.app'), 'app-1');
});

test('refuses when no app matches the bundle ID', async () => {
  const { request } = fakeApi([{ method: 'GET', path: '/apps?', body: { data: [{ id: 'x', attributes: { bundleId: 'other.app' } }] } }]);
  await assert.rejects(findAppId(request, 'example.app'), /found 0/);
});

test('waits through processing until the build is valid', async () => {
  const states = ['NOT_FOUND', 'PROCESSING', 'PROCESSING', 'VALID'];
  const { request } = fakeApi([{
    method: 'GET',
    path: '/builds?',
    body: () => {
      const state = states.shift();
      return state === 'NOT_FOUND' ? { data: [] } : build(state);
    },
  }]);
  const logged = [];
  let waits = 0;
  const result = await waitForProcessedBuild(request, 'app-1', 5, {
    wait: async () => { waits += 1; },
    log: (line) => logged.push(line),
  });
  assert.equal(result.id, 'build-1');
  assert.equal(waits, 3);
  assert.deepEqual(logged, ['Build 5: NOT_FOUND', 'Build 5: PROCESSING', 'Build 5: VALID']);
});

test('stops when processing fails', async () => {
  const { request } = fakeApi([{ method: 'GET', path: '/builds?', body: build('INVALID') }]);
  await assert.rejects(waitForProcessedBuild(request, 'app-1', 5, { wait: async () => {}, log: () => {} }), /INVALID/);
});

test('gives up after the timeout', async () => {
  let clock = 0;
  const { request } = fakeApi([{ method: 'GET', path: '/builds?', body: build('PROCESSING') }]);
  await assert.rejects(
    waitForProcessedBuild(request, 'app-1', 5, {
      timeoutMs: 60_000,
      now: () => clock,
      wait: async (ms) => { clock += ms; },
      log: () => {},
    }),
    /not processed within 1 minutes/,
  );
});

test('adds the build only to internal groups that do not get every build', async () => {
  const { calls, request } = fakeApi([
    {
      method: 'GET',
      path: '/apps/app-1/betaGroups',
      body: {
        data: [
          { id: 'manual', attributes: { isInternalGroup: true, hasAccessToAllBuilds: false } },
          { id: 'auto', attributes: { isInternalGroup: true, hasAccessToAllBuilds: true } },
          { id: 'external', attributes: { isInternalGroup: false, hasAccessToAllBuilds: false } },
        ],
      },
    },
    { method: 'POST', path: '/betaGroups/', body: null },
  ]);
  const result = await addBuildToInternalGroups(request, 'app-1', 'build-1');
  assert.deepEqual(result, { added: 1, automatic: 1 });
  const posts = calls.filter(({ method }) => method === 'POST');
  assert.deepEqual(posts, [{
    method: 'POST',
    path: '/betaGroups/manual/relationships/builds',
    body: { data: [{ type: 'builds', id: 'build-1' }] },
  }]);
});

test('API errors do not echo the response body', async () => {
  const { request } = fakeApi([{ method: 'GET', path: '/apps?', status: 403, body: { detail: 'Team Example Person' } }]);
  await assert.rejects(findAppId(request, 'example.app'), (error) =>
    /status 403/.test(error.message) && !error.message.includes('Example Person'));
});
