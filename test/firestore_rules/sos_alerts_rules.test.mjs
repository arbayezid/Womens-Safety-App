// Firestore emulator test for the sos_alerts lifecycle rules (Test plan row 16 and the create /
// re-ring rules). No npm packages: Node's built-in test runner and fetch, and the emulator's REST
// API with unsigned test tokens. Runs only against the local emulator, never the real project.
//
// 1. Start the Firestore emulator (any of):
//      firebase emulators:start --only firestore --project demo-phantom-sos
//      java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --host=127.0.0.1 --port=8085
// 2. node --test test/firestore_rules/
//
// FIRESTORE_EMULATOR_HOST overrides the default 127.0.0.1:8085.
import { test, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8085';
const PROJECT = 'demo-phantom-sos'; // demo-* projects never reach real Firebase resources
const BASE = `http://${HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;
const SENDER = { uid: 'sender_a', email: 'a@example.com' };
const GUARDIAN = { uid: 'guardian_b', email: 'b@example.com' };

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function tokenFor({ uid, email }) {
  const iat = Math.floor(Date.now() / 1000);
  return `${b64({ alg: 'none', kid: 'fakekid', typ: 'JWT' })}.${b64({
    iss: `https://securetoken.google.com/${PROJECT}`, aud: PROJECT, iat, exp: iat + 3600,
    auth_time: iat, sub: uid, user_id: uid, email, email_verified: true,
    firebase: { sign_in_provider: 'custom', identities: {} },
  })}.`;
}

function toValue(v) {
  if (v === null) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(toValue) } };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (Number.isInteger(v)) return { integerValue: String(v) };
  if (typeof v === 'number') return { doubleValue: v };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, toValue(x)])) } };
}
const fields = (data) => Object.fromEntries(Object.entries(data).map(([k, v]) => [k, toValue(v)]));
const docName = (id) => `projects/${PROJECT}/databases/(default)/documents/sos_alerts/${id}`;
const hoursFromNow = (h) => new Date(Date.now() + h * 3600 * 1000);

/** Runs one write as [as] ('owner' bypasses rules). Returns the HTTP status (200 or 403). */
async function commit(as, write) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${as === 'owner' ? 'owner' : tokenFor(as)}` },
    body: JSON.stringify({ writes: [write] }),
  });
  await res.text();
  return res.status;
}
const create = (as, id, data, transforms = [{ fieldPath: 'triggeredAt', setToServerValue: 'REQUEST_TIME' }]) =>
  commit(as, { update: { name: docName(id), fields: fields(data) }, currentDocument: { exists: false }, updateTransforms: transforms });
const update = (as, id, data, transforms = []) =>
  commit(as, {
    update: { name: docName(id), fields: fields(data) },
    updateMask: { fieldPaths: Object.keys(data) },
    currentDocument: { exists: true },
    updateTransforms: transforms,
  });

function alertData(extra = {}) {
  return {
    senderId: SENDER.uid, sender_uid: SENDER.uid, senderName: 'A',
    recipientUids: [GUARDIAN.uid], recipientEmails: [GUARDIAN.email],
    source: 'SOS Button', origin: 'manual', ringSeq: 0, expiresAt: hoursFromNow(2),
    status: 'active', ...extra,
  };
}
/** Seeds an alert directly (rules bypassed), like an existing document. */
const seed = (id, extra = {}) => create('owner', id, { ...alertData(extra), triggeredAt: new Date() }, []);

before(async () => {
  const rules = await readFile(new URL('../../firestore.rules', import.meta.url), 'utf8');
  const res = await fetch(`http://${HOST}/emulator/v1/projects/${PROJECT}:securityRules`, {
    method: 'PUT',
    body: JSON.stringify({ rules: { files: [{ name: 'firestore.rules', content: rules }] } }),
  });
  assert.equal(res.status, 200, `could not load rules into the emulator: ${await res.text()}`);
});

beforeEach(async () => {
  await fetch(`http://${HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
});

test('row 16: a guardian cannot set a resolved alert back to active', async () => {
  await seed('r16', { status: 'resolved' });
  assert.equal(await update(GUARDIAN, 'r16', { status: 'active' }), 403);
});

test('a guardian may resolve, dismiss and acknowledge, but not invent a status', async () => {
  await seed('g1');
  assert.equal(await update(GUARDIAN, 'g1', { status: 'cancelled' }), 403);
  assert.equal(await update(GUARDIAN, 'g1', {}, [
    { fieldPath: 'dismissedBy', appendMissingElements: { values: [{ stringValue: GUARDIAN.uid }] } },
  ]), 200);
  assert.equal(await update(GUARDIAN, 'g1', { status: 'resolved' }), 200);
});

test('the sender cannot revive an ended alert', async () => {
  await seed('s1', { status: 'resolved' });
  assert.equal(await update(SENDER, 's1', { status: 'active' }), 403);
});

test('create: active, ring 0, manual/automatic origin, expiry within 3 h, server trigger time', async () => {
  assert.equal(await create(SENDER, 'c-ok', alertData()), 200);
  assert.equal(await create(SENDER, 'c-auto', alertData({ origin: 'automatic' })), 200);
  const { origin, ...noOrigin } = alertData();
  assert.equal(await create(SENDER, 'c-no-origin', noOrigin), 403);
  const { expiresAt, ...noExpiry } = alertData();
  assert.equal(await create(SENDER, 'c-no-expiry', noExpiry), 403);
  assert.equal(await create(SENDER, 'c-long', alertData({ expiresAt: hoursFromNow(5) })), 403);
  assert.equal(await create(SENDER, 'c-ring', alertData({ ringSeq: 1 })), 403);
  assert.equal(await create(SENDER, 'c-resolved', alertData({ status: 'resolved' })), 403);
  assert.equal(await create(SENDER, 'c-client-time', { ...alertData(), triggeredAt: new Date() }, []), 403);
  assert.equal(await create(GUARDIAN, 'c-other', alertData()), 403);
});

test('re-ring: the sender bumps ringSeq by exactly 1 and may only clear dismissals', async () => {
  await seed('rr', { dismissedBy: [GUARDIAN.uid] });
  const reRing = [
    { fieldPath: 'ringSeq', increment: { integerValue: '1' } },
    { fieldPath: 'lastUpdatedAt', setToServerValue: 'REQUEST_TIME' },
  ];
  assert.equal(await update(SENDER, 'rr', { dismissedBy: [], expiresAt: hoursFromNow(2) }, reRing), 200);
  assert.equal(await update(SENDER, 'rr', {}, [{ fieldPath: 'ringSeq', increment: { integerValue: '2' } }]), 403);
  assert.equal(await update(SENDER, 'rr', { dismissedBy: ['someone'] }), 403);
});

test('expiry: the sender may extend it, but never beyond 3 h from now', async () => {
  await seed('ex');
  assert.equal(await update(SENDER, 'ex', { expiresAt: hoursFromNow(2) }), 200);
  assert.equal(await update(SENDER, 'ex', { expiresAt: hoursFromNow(5) }), 403);
});
