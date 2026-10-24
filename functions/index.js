const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

/**
 * 1. Listen for new Connection Requests to send push notification to Receiver (User B)
 * Handles both receiver_uid and receiver_email lookup.
 */
exports.onConnectionRequestCreated = onDocumentCreated("connection_requests/{requestId}", async (event) => {
  const requestData = event.data?.data();
  if (!requestData || requestData.status !== "pending") return;

  const senderName = requestData.sender_name || requestData.senderName || "Emergency Contact";
  const senderEmail = requestData.sender_email || requestData.senderEmail || "";
  const receiverId = requestData.receiver_uid || requestData.receiverId;
  const receiverEmail = (requestData.receiver_email || requestData.receiverEmail || "").toLowerCase().trim();
  const relationship = requestData.relationship || "Guardian";

  try {
    let receiverToken = null;

    // 1. Find receiver user document
    if (receiverId) {
      const receiverDoc = await db.collection("users").doc(receiverId).get();
      if (receiverDoc.exists) {
        const data = receiverDoc.data();
        receiverToken = data.fcm_token || data.fcmToken;
      }
    }

    if (!receiverToken && receiverEmail) {
      const userSnap = await db.collection("users")
        .where("email", "==", receiverEmail)
        .limit(1)
        .get();
      if (!userSnap.empty) {
        const data = userSnap.docs[0].data();
        receiverToken = data.fcm_token || data.fcmToken;
      }
    }

    if (!receiverToken) {
      console.log(`[FCM] Receiver ${receiverEmail || receiverId} has no active FCM token.`);
      return;
    }

    // 2. Dispatch High-Priority Connection Request FCM
    const message = {
      token: receiverToken,
      notification: {
        title: "🛡️ New Emergency Contact Request",
        body: `${senderName} wants to add you as their emergency contact (${relationship}).`,
      },
      data: {
        type: "CONNECTION_REQUEST",
        requestId: event.params.requestId,
        senderId: requestData.sender_uid || requestData.senderId || "",
        senderName: senderName,
        senderEmail: senderEmail,
        relationship: relationship,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
        notification: {
          channelId: "sos_emergency_channel",
          color: "#5A4FCF",
          defaultSound: true,
          defaultVibrateTimings: true,
        },
      },
      apns: {
        payload: {
          aps: { sound: "default", badge: 1 },
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log(`[FCM] Connection request notification sent: ${response}`);
  } catch (error) {
    console.error("[FCM] Error sending request notification:", error);
  }
});

/**
 * 2. Listen for Connection Request updates (Accept / Reject)
 * Atomically updates mutual emergency contact documents upon acceptance.
 */
exports.onConnectionRequestUpdated = onDocumentUpdated("connection_requests/{requestId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();

  if (!before || !after) return;
  // Trigger only when transitioning from pending -> accepted
  if (before.status === "pending" && after.status === "accepted") {
    const senderId = after.sender_uid || after.senderId;
    const receiverId = after.receiver_uid || after.receiverId;
    const relationship = after.relationship || "Guardian";

    const batch = db.batch();

    // 1. Fetch profiles of both users
    const [senderSnap, receiverSnap] = await Promise.all([
      db.collection("users").doc(senderId).get(),
      db.collection("users").doc(receiverId).get(),
    ]);

    if (!senderSnap.exists || !receiverSnap.exists) {
      console.error("[Sync] User documents not found for mutual sync.");
      return;
    }

    const sender = senderSnap.data();
    const receiver = receiverSnap.data();

    // 2. Add/Update Receiver B into Sender A's emergency contacts
    const senderContactRef = db.collection("users").doc(senderId).collection("contacts").doc(receiverId);
    batch.set(senderContactRef, {
      id: receiverId,
      contact_uid: receiverId,
      contactUid: receiverId,
      name: receiver.displayName || receiver.name || "Emergency Contact",
      contact_name: receiver.displayName || receiver.name || "Emergency Contact",
      email: (receiver.email || "").toLowerCase().trim(),
      contact_email: (receiver.email || "").toLowerCase().trim(),
      phone: receiver.phoneNumber || receiver.phone || "",
      contact_optional_phone: receiver.phoneNumber || receiver.phone || "",
      relationship: relationship,
      isPrimary: true,
      isSyncedAppUser: true,
      is_synced_app_user: true,
      syncStatus: "synced",
      sync_status: "synced",
      fcmToken: receiver.fcm_token || receiver.fcmToken || "",
      syncedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // 3. Mutual Sync: Add/Update Sender A into Receiver B's emergency contacts
    const receiverContactRef = db.collection("users").doc(receiverId).collection("contacts").doc(senderId);
    batch.set(receiverContactRef, {
      id: senderId,
      contact_uid: senderId,
      contactUid: senderId,
      name: sender.displayName || sender.name || "Emergency Ward",
      contact_name: sender.displayName || sender.name || "Emergency Ward",
      email: (sender.email || "").toLowerCase().trim(),
      contact_email: (sender.email || "").toLowerCase().trim(),
      phone: sender.phoneNumber || sender.phone || "",
      contact_optional_phone: sender.phoneNumber || sender.phone || "",
      relationship: "Safety Ward",
      isPrimary: true,
      isSyncedAppUser: true,
      is_synced_app_user: true,
      syncStatus: "synced",
      sync_status: "synced",
      fcmToken: sender.fcm_token || sender.fcmToken || "",
      syncedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    await batch.commit();
    console.log(`[Sync] Mutual emergency contacts created between ${senderId} and ${receiverId}`);

    // Notify Sender A that Receiver B accepted
    const senderFCM = sender.fcm_token || sender.fcmToken;
    if (senderFCM) {
      try {
        await admin.messaging().send({
          token: senderFCM,
          notification: {
            title: "✅ Request Accepted",
            body: `${receiver.displayName || receiver.name || "User"} is now your synced Emergency Contact.`,
          },
          data: {
            type: "REQUEST_ACCEPTED",
            contactUid: receiverId,
          },
        });
      } catch (err) {
        console.error("[FCM] Error notifying sender of acceptance:", err);
      }
    }
  }
});

/**
 * 3. High-Priority SOS Alert Dispatcher
 * Triggered when a new document is created in `sos_alerts`.
 * Queries all accepted emergency contacts and sends a high-priority FCM payload.
 */
exports.onSosAlertTriggered = onDocumentCreated("sos_alerts/{alertId}", async (event) => {
  const alertData = event.data?.data();
  if (!alertData || alertData.status !== "active") return;

  const senderId = alertData.sender_uid || alertData.senderId;
  const senderName = alertData.sender_name || alertData.senderName || "Emergency Contact";
  const senderPhone = alertData.sender_phone || alertData.senderPhone || "";
  const senderEmail = alertData.sender_email || alertData.senderEmail || "";
  const alertId = event.params.alertId;

  const latitude = alertData.latitude || alertData.location?.latitude || 0;
  const longitude = alertData.longitude || alertData.location?.longitude || 0;
  const googleMapsUrl = alertData.google_maps_url || alertData.location?.googleMapsUrl || `https://maps.google.com/?q=${latitude},${longitude}`;
  const address = alertData.location?.address || `Lat: ${latitude}, Lng: ${longitude}`;
  const messageText = alertData.message || alertData.note || `${senderName} has triggered an SOS alert!`;

  try {
    // 1. Gather candidate recipient UIDs from multiple sources:
    // a) Explicit recipientUids written into sos_alerts document
    const candidateUids = new Set(
      Array.isArray(alertData.recipientUids) ? alertData.recipientUids.filter((u) => u && !u.startsWith("offline_")) : []
    );

    // b) Query contacts in Sender's `contacts` subcollection (include both synced and pending contacts)
    try {
      const contactsSnap = await db.collection("users").doc(senderId).collection("contacts").get();
      contactsSnap.docs.forEach((doc) => {
        const d = doc.data();
        const uid = d.contact_uid || d.contactUid || doc.id;
        if (uid && !uid.startsWith("offline_") && !uid.startsWith("pending_")) {
          candidateUids.add(uid);
        }
      });
    } catch (e) {
      console.warn("[SOS] Error reading sender contacts subcollection:", e);
    }

    // c) If recipientEmails are present, resolve any missing UIDs
    const recipientEmails = Array.isArray(alertData.recipientEmails)
      ? alertData.recipientEmails.map((e) => String(e).toLowerCase().trim()).filter((e) => e.length > 0)
      : [];

    if (recipientEmails.length > 0) {
      try {
        const emailDocs = await db.collection("users")
          .where("email", "in", recipientEmails.slice(0, 30))
          .get();
        emailDocs.docs.forEach((doc) => candidateUids.add(doc.id));
      } catch (emailErr) {
        console.warn("[SOS] Error resolving recipient emails to UIDs:", emailErr);
      }
    }

    const targetUids = Array.from(candidateUids).filter((uid) => uid !== senderId);

    if (targetUids.length === 0) {
      console.warn(`[SOS] User ${senderId} has 0 target recipient UIDs.`);
      return;
    }

    // 2. Fetch fresh FCM tokens of all contacts from `users` collection
    const userDocsSnap = await db.collection("users")
      .where(admin.firestore.FieldPath.documentId(), "in", targetUids.slice(0, 30))
      .get();

    const tokens = [];
    const uidTokenMap = new Map();

    userDocsSnap.forEach((doc) => {
      const data = doc.data();
      const token = data.fcm_token || data.fcmToken;
      if (token && typeof token === "string" && token.length > 10) {
        tokens.push(token);
        uidTokenMap.set(token, doc.id);
      }
    });

    if (tokens.length === 0) {
      console.warn(`[SOS] No valid FCM tokens available for recipients of user ${senderId}.`);
      return;
    }

    // 3. Build High-Priority Urgent Multicast Payload
    const uniqueTokens = [...new Set(tokens)];
    const message = {
      tokens: uniqueTokens,
      notification: {
        title: `🚨 EMERGENCY SOS: ${senderName} Needs Help!`,
        body: `Immediate assistance requested! Tap to view live GPS location & route.`,
      },
      data: {
        type: "SOS_ALERT",
        alertId: alertId,
        senderId: senderId,
        senderName: senderName,
        senderPhone: senderPhone,
        senderEmail: senderEmail,
        latitude: String(latitude),
        longitude: String(longitude),
        address: String(address),
        googleMapsUrl: String(googleMapsUrl),
        message: String(messageText),
        timestamp: String(Date.now()),
      },
      android: {
        priority: "high",
        ttl: 0, // Instant delivery
        notification: {
          channelId: "sos_emergency_channel_v2",
          sound: "siren",
          defaultVibrateTimings: true,
          visibility: "public",
          color: "#FF3B30",
          priority: "max",
        },
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
        },
        payload: {
          aps: {
            sound: "emergency_siren.caf",
            badge: 1,
            critical: 1,
          },
        },
      },
    };

    // 4. Multicast dispatch
    const response = await admin.messaging().sendEachForMulticast(message);
    console.log(`[SOS] Dispatched SOS to ${response.successCount}/${uniqueTokens.length} devices.`);

    // 5. Clean up stale/invalid tokens
    const staleUids = [];
    response.responses.forEach((resp, idx) => {
      if (!resp.success) {
        const errCode = resp.error?.code;
        if (
          errCode === "messaging/invalid-registration-token" ||
          errCode === "messaging/registration-token-not-registered"
        ) {
          const badToken = uniqueTokens[idx];
          const targetUid = uidTokenMap.get(badToken);
          if (targetUid) staleUids.push(targetUid);
        }
      }
    });

    if (staleUids.length > 0) {
      const cleanBatch = db.batch();
      staleUids.forEach((uid) => {
        cleanBatch.update(db.collection("users").doc(uid), { fcmToken: null, fcm_token: null });
      });
      await cleanBatch.commit();
      console.log(`[SOS] Evicted ${staleUids.length} invalid tokens.`);
    }

    // 6. Record notified UIDs in the alert document
    await db.collection("sos_alerts").doc(alertId).update({
      notifiedUids: contactUids,
      dispatchedCount: response.successCount,
    });
  } catch (error) {
    console.error("[SOS] Error broadcasting SOS alert:", error);
  }
});
