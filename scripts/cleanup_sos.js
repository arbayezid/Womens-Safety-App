// One-off cleanup after the phantom-SOS fix (see "Firestore rules and data cleanup").
// Resolves every alert still active and older than 3 hours, and deletes safety deadlines more
// than 24 hours past due. Runs locally with the Admin SDK (no Cloud Functions needed).
//
// Run only after the new rules are deployed and the Phase 3 build is on every phone:
//   node scripts/cleanup_sos.js
// Needs scripts/service-account.json (never commit it; it is in .gitignore) and the
// firebase-admin package (e.g. run from a folder where it is installed).
const admin = require('firebase-admin');
admin.initializeApp({ credential: admin.credential.cert(require('./service-account.json')) });
const db = admin.firestore();

(async () => {
  const cutoff = Date.now() - 3 * 60 * 60 * 1000;
  let batch = db.batch(), n = 0;
  const flush = async () => { await batch.commit(); batch = db.batch(); };

  const alerts = await db.collection('sos_alerts').where('status', '==', 'active').get();
  for (const doc of alerts.docs) {
    const t = doc.get('triggeredAt');
    if (t && t.toMillis() > cutoff) continue; // a genuinely recent alert stays live
    batch.update(doc.ref, {
      status: 'resolved',
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
      endReason: 'expired_cleanup',
    });
    if (++n % 400 === 0) await flush();
  }

  const deadlines = await db.collectionGroup('safety_deadlines').get();
  for (const doc of deadlines.docs) {
    const fireAt = doc.get('fireAt');
    if (fireAt && fireAt.toMillis() < Date.now() - 24 * 60 * 60 * 1000) {
      batch.delete(doc.ref);
      if (++n % 400 === 0) await flush();
    }
  }
  await flush();
  console.log(`Cleaned ${n} documents`);
})();
