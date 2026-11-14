// Waits until App Store Connect finishes processing an uploaded build, then
// adds it to the app's internal TestFlight groups, so testers get every build
// without anyone adding it by hand. Groups that already receive all builds
// automatically are left alone.
// The repository is public: this prints counts and states, never group names,
// IDs, the bundle ID, or API response bodies.
import { readFile } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { createAppStoreConnectToken } from './apple-signing-certificates.mjs';

const API_BASE_URL = 'https://api.appstoreconnect.apple.com/v1';
const DEFAULT_TIMEOUT_MS = 60 * 60 * 1000;
const DEFAULT_POLL_MS = 30 * 1000;
// Tokens live 15 minutes; renew well before that while waiting on processing.
const TOKEN_RENEW_MS = 10 * 60 * 1000;

export function createClient({ fetchImpl = fetch, tokenProvider }) {
  return async function request(path, { method = 'GET', body } = {}) {
    const response = await fetchImpl(`${API_BASE_URL}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${tokenProvider()}`,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok) {
      throw new Error(`App Store Connect API ${method} failed with status ${response.status}.`);
    }
    return response.status === 204 ? null : response.json();
  };
}

export async function findAppId(request, bundleId) {
  const query = new URLSearchParams({ 'filter[bundleId]': bundleId, 'fields[apps]': 'bundleId', limit: '2' });
  const response = await request(`/apps?${query}`);
  const apps = (response?.data ?? []).filter((app) => app.attributes?.bundleId === bundleId);
  if (apps.length !== 1) {
    throw new Error(`Expected one App Store Connect app for the bundle ID, found ${apps.length}.`);
  }
  return apps[0].id;
}

export async function findBuild(request, appId, buildNumber) {
  const query = new URLSearchParams({
    'filter[app]': appId,
    'filter[version]': String(buildNumber),
    'fields[builds]': 'version,processingState',
    limit: '2',
  });
  const response = await request(`/builds?${query}`);
  const builds = (response?.data ?? []).filter((build) => build.attributes?.version === String(buildNumber));
  return builds[0] ?? null;
}

export async function waitForProcessedBuild(request, appId, buildNumber, {
  timeoutMs = DEFAULT_TIMEOUT_MS,
  pollMs = DEFAULT_POLL_MS,
  now = Date.now,
  wait = sleep,
  log = console.log,
} = {}) {
  const deadline = now() + timeoutMs;
  let lastState = null;
  for (;;) {
    const build = await findBuild(request, appId, buildNumber);
    const state = build?.attributes?.processingState ?? 'NOT_FOUND';
    if (state !== lastState) {
      log(`Build ${buildNumber}: ${state}`);
      lastState = state;
    }
    if (state === 'VALID') {
      return build;
    }
    if (state === 'FAILED' || state === 'INVALID') {
      throw new Error(`Build ${buildNumber} processing ended in ${state}.`);
    }
    if (now() >= deadline) {
      throw new Error(`Build ${buildNumber} was not processed within ${Math.round(timeoutMs / 60000)} minutes.`);
    }
    await wait(pollMs);
  }
}

export async function listInternalGroups(request, appId) {
  const query = new URLSearchParams({
    'fields[betaGroups]': 'name,isInternalGroup,hasAccessToAllBuilds',
    limit: '200',
  });
  const response = await request(`/apps/${encodeURIComponent(appId)}/betaGroups?${query}`);
  return (response?.data ?? []).filter((group) => group.attributes?.isInternalGroup === true);
}

export async function addBuildToInternalGroups(request, appId, buildId) {
  const groups = await listInternalGroups(request, appId);
  const automatic = groups.filter((group) => group.attributes?.hasAccessToAllBuilds === true);
  const manual = groups.filter((group) => group.attributes?.hasAccessToAllBuilds !== true);
  for (const group of manual) {
    await request(`/betaGroups/${encodeURIComponent(group.id)}/relationships/builds`, {
      method: 'POST',
      body: { data: [{ type: 'builds', id: buildId }] },
    });
  }
  return { added: manual.length, automatic: automatic.length };
}

async function runCli() {
  const bundleId = process.env.CLIPBOARD_PLUS_BUNDLE_ID;
  const buildNumber = process.env.BUILD_NUMBER;
  const issuerId = process.env.APP_STORE_CONNECT_API_ISSUER_ID;
  const keyId = process.env.APP_STORE_CONNECT_API_KEY_ID;
  const keyPath = process.env.APP_STORE_CONNECT_API_KEY_PATH;
  if (!bundleId || !buildNumber || !issuerId || !keyId || !keyPath) {
    throw new Error('CLIPBOARD_PLUS_BUNDLE_ID, BUILD_NUMBER, and the App Store Connect key variables are required.');
  }
  const privateKey = await readFile(keyPath, 'utf8');
  let token = null;
  let issuedAt = 0;
  const tokenProvider = () => {
    if (!token || Date.now() - issuedAt > TOKEN_RENEW_MS) {
      token = createAppStoreConnectToken({ issuerId, keyId, privateKey });
      issuedAt = Date.now();
    }
    return token;
  };
  const request = createClient({ tokenProvider });

  const appId = await findAppId(request, bundleId);
  const build = await waitForProcessedBuild(request, appId, buildNumber);
  const { added, automatic } = await addBuildToInternalGroups(request, appId, build.id);
  console.log(`Added build ${buildNumber} to ${added} internal group(s); ${automatic} group(s) receive every build automatically.`);
  if (added + automatic === 0) {
    console.log('::warning::No internal TestFlight group exists for this app, so no tester receives the build.');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCli().catch((error) => {
    console.error(error instanceof Error ? error.message : 'TestFlight distribution failed.');
    process.exitCode = 1;
  });
}
