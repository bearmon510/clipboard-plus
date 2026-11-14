// Revokes the Apple Development certificate that cloud signing creates on a
// fresh CI runner, so certificates do not pile up across TestFlight runs.
// The repository is public, so nothing here prints certificate names or API
// response bodies: either can carry the developer's name or team details.
import { createHash, sign } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

const API_BASE_URL = 'https://api.appstoreconnect.apple.com/v1';
const DEFAULT_MAX_REVOKE_COUNT = 1;
const TOKEN_AUDIENCE = 'appstoreconnect-v1';
const TOKEN_LIFETIME_SECONDS = 15 * 60;

const encodeJson = (value) => Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');

export function createAppStoreConnectToken({
  issuerId,
  keyId,
  privateKey,
  nowSeconds = Math.floor(Date.now() / 1000),
}) {
  const header = encodeJson({ alg: 'ES256', kid: keyId, typ: 'JWT' });
  const payload = encodeJson({
    aud: TOKEN_AUDIENCE,
    exp: nowSeconds + TOKEN_LIFETIME_SECONDS,
    iat: nowSeconds - 5,
    iss: issuerId,
  });
  const unsignedToken = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(unsignedToken), {
    dsaEncoding: 'ieee-p1363',
    key: privateKey,
  }).toString('base64url');
  return `${unsignedToken}.${signature}`;
}

async function requestAppStoreConnect(path, { fetchImpl = fetch, method = 'GET', token }) {
  const response = await fetchImpl(`${API_BASE_URL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    method,
  });
  if (!response.ok) {
    throw new Error(`App Store Connect API ${method} failed with status ${response.status}.`);
  }
  return response.status === 204 ? null : response.json();
}

export async function listDevelopmentCertificates({ fetchImpl, token }) {
  const query = new URLSearchParams({
    'fields[certificates]': 'name,displayName,certificateType,platform,expirationDate,activated,certificateContent',
    'filter[certificateType]': 'DEVELOPMENT',
    limit: '200',
  });
  const response = await requestAppStoreConnect(`/certificates?${query}`, { fetchImpl, token });
  if (!Array.isArray(response?.data) || response.links?.next) {
    throw new Error('Incomplete certificate inventory; refusing cleanup.');
  }
  return response.data;
}

export function certificateFingerprint(certificate) {
  const content = certificate.attributes?.certificateContent;
  return content
    ? createHash('sha1').update(Buffer.from(content, 'base64')).digest('hex').toUpperCase()
    : null;
}

export function isEphemeralApiDevelopmentCertificate(certificate) {
  const attributes = certificate?.attributes ?? {};
  const label = `${attributes.name ?? ''} ${attributes.displayName ?? ''}`;
  return (
    certificate?.type === 'certificates' &&
    attributes.certificateType === 'DEVELOPMENT' &&
    attributes.activated !== false &&
    label.includes('Created via API')
  );
}

export function findCertificatesCreatedSince(beforeIds, certificates) {
  const knownIds = new Set(beforeIds);
  return certificates.filter(
    (certificate) => !knownIds.has(certificate.id) && isEphemeralApiDevelopmentCertificate(certificate),
  );
}

export async function revokeCertificatesCreatedSince({
  apply = false,
  beforeIds,
  fetchImpl,
  maxRevokeCount = DEFAULT_MAX_REVOKE_COUNT,
  ownedFingerprints = [],
  token,
}) {
  const certificates = await listDevelopmentCertificates({ fetchImpl, token });
  const created = findCertificatesCreatedSince(beforeIds, certificates);
  if (created.length > maxRevokeCount) {
    throw new Error(`Refusing to revoke ${created.length} certificates; expected at most ${maxRevokeCount}.`);
  }
  if (apply) {
    // Another run for the same team may have created a certificate meanwhile.
    if (created.some((certificate) => !ownedFingerprints.includes(certificateFingerprint(certificate)))) {
      throw new Error('New certificate is not owned by this runner; refusing cleanup.');
    }
    for (const certificate of created) {
      await requestAppStoreConnect(`/certificates/${encodeURIComponent(certificate.id)}`, {
        fetchImpl,
        method: 'DELETE',
        token,
      });
    }
  }
  return created.map((certificate) => certificate.id);
}

function readOption(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

async function readCredentials() {
  const issuerId = process.env.APP_STORE_CONNECT_API_ISSUER_ID;
  const keyId = process.env.APP_STORE_CONNECT_API_KEY_ID;
  const privateKeyPath = process.env.APP_STORE_CONNECT_API_KEY_PATH;
  if (!issuerId || !keyId || !privateKeyPath) {
    throw new Error(
      'APP_STORE_CONNECT_API_ISSUER_ID, APP_STORE_CONNECT_API_KEY_ID, and APP_STORE_CONNECT_API_KEY_PATH are required.',
    );
  }
  return { issuerId, keyId, privateKey: await readFile(privateKeyPath, 'utf8') };
}

async function runCli() {
  const [command, ...args] = process.argv.slice(2);
  const token = createAppStoreConnectToken(await readCredentials());

  if (command === 'snapshot') {
    const outputPath = readOption(args, '--output');
    if (!outputPath) {
      throw new Error('snapshot requires --output <path>.');
    }
    const certificates = await listDevelopmentCertificates({ token });
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify({ ids: certificates.map(({ id }) => id) })}\n`, 'utf8');
    console.log(`Captured ${certificates.length} development certificate IDs.`);
    return;
  }

  if (command === 'cleanup-created') {
    const beforePath = readOption(args, '--before');
    if (!beforePath) {
      throw new Error('cleanup-created requires --before <snapshot path>.');
    }
    const before = JSON.parse(await readFile(beforePath, 'utf8'));
    if (!Array.isArray(before.ids) || before.ids.some((id) => typeof id !== 'string')) {
      throw new Error('Invalid certificate snapshot; refusing cleanup.');
    }
    const identitiesPath = readOption(args, '--identities');
    const identities = identitiesPath ? await readFile(identitiesPath, 'utf8') : '';
    const ownedFingerprints = [...identities.matchAll(/\b[A-Fa-f0-9]{40}\b/g)].map(([value]) => value.toUpperCase());
    const apply = args.includes('--apply');
    const ids = await revokeCertificatesCreatedSince({ apply, beforeIds: before.ids, ownedFingerprints, token });
    console.log(`${apply ? 'Revoked' : 'Would revoke'} ${ids.length} certificate(s) created by this run.`);
    return;
  }

  throw new Error('Usage: apple-signing-certificates.mjs snapshot --output <path> | cleanup-created --before <path> [--identities <path>] [--apply]');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCli().catch((error) => {
    console.error(error instanceof Error ? error.message : 'Certificate cleanup failed.');
    process.exitCode = 1;
  });
}
