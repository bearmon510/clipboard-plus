import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';
import {
  certificateFingerprint,
  createAppStoreConnectToken,
  findCertificatesCreatedSince,
  revokeCertificatesCreatedSince,
} from './apple-signing-certificates.mjs';

const certificate = (id, overrides = {}) => ({
  attributes: {
    activated: true,
    certificateContent: Buffer.from(id).toString('base64'),
    certificateType: 'DEVELOPMENT',
    displayName: 'Apple Development: Created via API',
    name: 'Created via API',
    platform: 'IOS',
    ...overrides,
  },
  id,
  type: 'certificates',
});

/** A fetch stand-in that records calls and answers listings with `listing()`. */
function fakeFetch(listing) {
  const calls = [];
  const fetchImpl = async (url, options = {}) => {
    calls.push({ url, method: options.method ?? 'GET' });
    if ((options.method ?? 'GET') === 'DELETE') {
      return new Response(null, { status: 204 });
    }
    return new Response(JSON.stringify(listing()), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    });
  };
  return { calls, fetchImpl };
}

test('creates a short-lived ES256 token', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const token = createAppStoreConnectToken({
    issuerId: 'issuer-id',
    keyId: 'KEY123',
    nowSeconds: 1_000,
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  });
  const [header, payload, signature] = token.split('.');

  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url').toString('utf8')), {
    alg: 'ES256',
    kid: 'KEY123',
    typ: 'JWT',
  });
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')), {
    aud: 'appstoreconnect-v1',
    exp: 1_900,
    iat: 995,
    iss: 'issuer-id',
  });
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
});

test('selects only new API-created development certificates', () => {
  const selected = findCertificatesCreatedSince(['old'], [
    certificate('old'),
    certificate('new'),
    certificate('manual', { displayName: 'Developer PC', name: 'Developer PC' }),
    certificate('distribution', { certificateType: 'DISTRIBUTION' }),
    certificate('revoked', { activated: false }),
  ]);
  assert.deepEqual(selected.map(({ id }) => id), ['new']);
});

test('revokes only the certificate this runner created', async () => {
  const { calls, fetchImpl } = fakeFetch(() => ({ data: [certificate('old'), certificate('new')] }));
  const revoked = await revokeCertificatesCreatedSince({
    apply: true,
    beforeIds: ['old'],
    ownedFingerprints: [certificateFingerprint(certificate('new'))],
    fetchImpl,
    token: 'token',
  });
  assert.deepEqual(revoked, ['new']);
  assert.deepEqual(calls.at(-1), {
    url: 'https://api.appstoreconnect.apple.com/v1/certificates/new',
    method: 'DELETE',
  });
});

test('a dry run deletes nothing', async () => {
  const { calls, fetchImpl } = fakeFetch(() => ({ data: [certificate('new')] }));
  const revoked = await revokeCertificatesCreatedSince({ beforeIds: [], fetchImpl, token: 'token' });
  assert.deepEqual(revoked, ['new']);
  assert.equal(calls.filter(({ method }) => method === 'DELETE').length, 0);
});

test('fails closed when more than one certificate appears', async () => {
  const { calls, fetchImpl } = fakeFetch(() => ({ data: [certificate('new-1'), certificate('new-2')] }));
  await assert.rejects(
    revokeCertificatesCreatedSince({ apply: true, beforeIds: [], fetchImpl, token: 'token' }),
    /Refusing to revoke 2 certificates/,
  );
  assert.equal(calls.length, 1);
});

test('never revokes a new certificate owned by another runner', async () => {
  const { calls, fetchImpl } = fakeFetch(() => ({ data: [certificate('other-runner')] }));
  await assert.rejects(
    revokeCertificatesCreatedSince({ apply: true, beforeIds: [], ownedFingerprints: [], fetchImpl, token: 'token' }),
    /not owned by this runner/,
  );
  assert.equal(calls.length, 1);
});

test('refuses incomplete inventories', async () => {
  const { fetchImpl } = fakeFetch(() => ({ data: [], links: { next: 'next-page' } }));
  await assert.rejects(
    revokeCertificatesCreatedSince({ apply: true, beforeIds: [], fetchImpl, token: 'token' }),
    /Incomplete certificate inventory/,
  );
});

test('API errors do not echo the response body', async () => {
  const fetchImpl = async () => new Response('{"detail":"Team Example Person"}', { status: 403 });
  await assert.rejects(
    revokeCertificatesCreatedSince({ beforeIds: [], fetchImpl, token: 'token' }),
    (error) => /status 403/.test(error.message) && !error.message.includes('Example Person'),
  );
});
