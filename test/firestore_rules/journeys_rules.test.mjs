// Firestore emulator test for the journeys rules: a guardian may mark only themselves as watching
// (Followed Mode shows the traveller who is watching); everything else stays owner-only.
// No npm packages. Runs only against the local emulator, never the real project.
//
// 1. Start the Firestore emulator (any of):
//      firebase emulators:start --only firestore --project demo-phantom-sos
//      java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --host=127.0.0.1 --port=8085
// 2. node --test --test-concurrency=1 test/firestore_rules/
//    (one file at a time: every file clears the same emulator before each test)
//
// FIRESTORE_EMULATOR_HOST overrides the default 127.0.0.1:8085.
import { test, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8085';
const PROJECT = 'demo-phantom-sos'; // demo-* projects never reach real Firebase resources
const BASE = `http://${HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;
const OWNER = { uid: 'owner_a', email: 'a@example.com' };
const GUARDIAN = { uid: 'guardian_b', email: 'b@example.com' };
const OTHER_GUARDIAN = { uid: 'guardian_c', email: 'c@example.com' };
const STRANGER = { uid: 'stranger_d', email: 'd@example.com' };

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
const docName = (id) => `projects/${PROJECT}/databases/(default)/documents/journeys/${id}`;

async function commit(as, write) {
  const res = await fetch(`${BASE}:commit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${as === 'owner' ? 'owner' : tokenFor(as)}` },
    body: JSON.stringify({ writes: [write] }),
  });
  await res.text();
  return res.status;
}

/** Seeds a Followed Mode journey directly (rules bypassed). */
const seed = (id, extra = {}) => commit('owner', {
  update: {
    name: docName(id),
    fields: fields({
      ownerId: OWNER.uid, ownerName: 'A', status: 'active', mode: 'followed',
      guardianUids: [GUARDIAN.uid, OTHER_GUARDIAN.uid], guardianEmails: [GUARDIAN.email, OTHER_GUARDIAN.email],
      startedAt: new Date(), lastUpdatedAt: new Date(), ...extra,
    }),
  },
});

/**
 * What JourneyService.markWatching sends: watchers.<uid> = {name, at: server time}.
 * [uid] is whose entry is written; [name] can be overridden to test validation.
 */
const markWatching = (as, id, { uid = as.uid, name = 'Rahim', extraFields = {}, serverTime = true } = {}) =>
  commit(as, {
    update: {
      name: docName(id),
      fields: { watchers: toValue({ [uid]: { name, ...(serverTime ? {} : { at: new Date() }), ...extraFields } }) },
    },
    updateMask: { fieldPaths: [`watchers.${uid}`] },
    currentDocument: { exists: true },
    updateTransforms: serverTime ? [{ fieldPath: `watchers.${uid}.at`, setToServerValue: 'REQUEST_TIME' }] : [],
  });

const updateFields = (as, id, data) => commit(as, {
  update: { name: docName(id), fields: fields(data) },
  updateMask: { fieldPaths: Object.keys(data) },
  currentDocument: { exists: true },
});

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

test('a guardian can mark themselves as watching, and refresh it', async () => {
  await seed('w1');
  assert.equal(await markWatching(GUARDIAN, 'w1'), 200);
  assert.equal(await markWatching(GUARDIAN, 'w1'), 200);
  assert.equal(await markWatching(OTHER_GUARDIAN, 'w1', { name: 'Karim' }), 200);
});

test("a guardian cannot write another guardian's entry", async () => {
  await seed('w2');
  assert.equal(await markWatching(GUARDIAN, 'w2', { uid: OTHER_GUARDIAN.uid }), 403);
});

test('the entry is only a name and the server time', async () => {
  await seed('w3');
  assert.equal(await markWatching(GUARDIAN, 'w3', { serverTime: false }), 403);
  assert.equal(await markWatching(GUARDIAN, 'w3', { extraFields: { role: 'admin' } }), 403);
  assert.equal(await markWatching(GUARDIAN, 'w3', { name: 'x'.repeat(81) }), 403);
});

test('someone who is not a guardian cannot mark watching', async () => {
  await seed('w4');
  assert.equal(await markWatching(STRANGER, 'w4'), 403);
});

test('a guardian still cannot change the journey itself', async () => {
  await seed('w5');
  assert.equal(await updateFields(GUARDIAN, 'w5', { status: 'arrived' }), 403);
  assert.equal(await updateFields(GUARDIAN, 'w5', { currentLocation: { latitude: 1, longitude: 2 } }), 403);
});

test('the owner can still update and link an SOS', async () => {
  await seed('w6');
  assert.equal(await updateFields(OWNER, 'w6', {
    status: 'alert', linkedSosAlertId: 'sos1', linkedSosDuress: true,
  }), 200);
});
