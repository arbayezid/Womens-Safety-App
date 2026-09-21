import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'auth_service.dart';
import 'contact_service.dart';

/// Service responsible for publishing real-time SOS alerts to Cloud Firestore,
/// triggering automated server-side FCM push notification broadcasts.
class SosCloudDispatcher {
  SosCloudDispatcher._internal();
  static final SosCloudDispatcher instance = SosCloudDispatcher._internal();

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Records an active SOS emergency in Firestore `sos_alerts` collection.
  ///
  /// Returns the generated [alertId] if successful, or null if unauthenticated or failed.
  Future<String?> triggerCloudSos({
    Position? position,
    String? customNote,
    String source = 'SOS Button',
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[SosCloud] Skipping cloud alert: user is unauthenticated or guest.');
      return null;
    }

    try {
      debugPrint('[SosCloud] 📡 Starting Cloud SOS dispatch for ${user.email ?? user.uid}...');

      String humanAddress = 'Live GPS Coordinates Unavailable';
      String mapsUrl = '';
      double latitude = 0.0;
      double longitude = 0.0;
      double accuracy = 0.0;

      if (position != null) {
        latitude = position.latitude;
        longitude = position.longitude;
        accuracy = position.accuracy;
        mapsUrl = 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
        humanAddress = 'Lat: ${latitude.toStringAsFixed(5)}, Lng: ${longitude.toStringAsFixed(5)}';
        try {
          final placemarks = await placemarkFromCoordinates(latitude, longitude)
              .timeout(const Duration(seconds: 3), onTimeout: () => []);
          if (placemarks.isNotEmpty) {
            final p = placemarks.first;
            final parts = [p.name, p.subLocality, p.locality, p.administrativeArea]
                .where((s) => s != null && s.trim().isNotEmpty)
                .toList();
            if (parts.isNotEmpty) {
              humanAddress = parts.join(', ');
            }
          }
        } catch (geoErr) {
          debugPrint('[SosCloud] Reverse geocoding fallback notice: $geoErr');
        }
      }

      // 2. Fetch all recipient emails and UIDs from Firestore contacts and local cache
      final List<String> recipientEmails = [];
      final List<String> recipientUids = [];

      try {
        final contactsSnap = await _firestore
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 2), onTimeout: () {
          debugPrint('[SosCloud] ⏱️ Contacts fetch timed out after 2s');
          throw Exception('Timeout');
        });

        for (final doc in contactsSnap.docs) {
          final d = doc.data();
          final email = (d['contact_email'] ?? d['email'] ?? '').toString().toLowerCase().trim();
          final uid = (d['contact_uid'] ?? d['contactUid'] ?? doc.id).toString().trim();
          if (email.isNotEmpty && !recipientEmails.contains(email)) {
            recipientEmails.add(email);
          }
          if (uid.isNotEmpty && !uid.startsWith('offline_') && !recipientUids.contains(uid)) {
            recipientUids.add(uid);
          }
        }
      } catch (e) {
        debugPrint('[SosCloud] Firestore contacts fetch notice: $e');
      }

      // Also include any locally cached contacts
      try {
        final localContacts = await ContactService.instance.getContacts();
        for (final c in localContacts) {
          final email = c.email.toLowerCase().trim();
          if (email.isNotEmpty && !recipientEmails.contains(email)) {
            recipientEmails.add(email);
          }
          if (c.contactUid != null && c.contactUid!.isNotEmpty && !recipientUids.contains(c.contactUid)) {
            recipientUids.add(c.contactUid!);
          }
        }
      } catch (e) {
        debugPrint('[SosCloud] Local contacts fetch notice: $e');
      }

      // Resolve any missing recipient UIDs from their emails in parallel
      if (recipientUids.isEmpty && recipientEmails.isNotEmpty) {
        try {
          await Future.wait(
            recipientEmails.map((email) async {
              try {
                final snap = await _firestore
                    .collection('users')
                    .where('email', isEqualTo: email)
                    .limit(1)
                    .get()
                    .timeout(const Duration(seconds: 2));
                if (snap.docs.isNotEmpty) {
                  final foundUid = snap.docs.first.id;
                  if (!recipientUids.contains(foundUid)) {
                    recipientUids.add(foundUid);
                  }
                }
              } catch (_) {}
            }),
          ).timeout(const Duration(seconds: 2), onTimeout: () => []);
        } catch (_) {}
      }

      debugPrint('[SosCloud] 👥 Recipient emails: $recipientEmails | UIDs: $recipientUids');

      // 3. Create document in `sos_alerts`
      final senderEmail = (user.email ?? '').toLowerCase().trim();
      final senderPhone = user.phoneNumber ?? AuthService.instance.currentProfile.phone;
      final senderName = user.displayName ?? AuthService.instance.displayName;
      final message = customNote ?? 'Emergency SOS Alert: $senderName needs immediate assistance!';

      final docRef = _firestore.collection('sos_alerts').doc();
      final alertId = docRef.id;

      await docRef.set({
        'alertId': alertId,
        'id': alertId,
        'senderId': user.uid,
        'sender_uid': user.uid,
        'senderName': senderName,
        'sender_name': senderName,
        'senderEmail': senderEmail,
        'sender_email': senderEmail,
        'senderPhone': senderPhone,
        'sender_phone': senderPhone,
        'recipientEmails': recipientEmails,
        'recipientUids': recipientUids,
        'source': source,
        'note': message,
        'message': message,
        'status': 'active',
        'latitude': latitude,
        'longitude': longitude,
        'google_maps_url': mapsUrl,
        'location': {
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
          'address': humanAddress,
          'googleMapsUrl': mapsUrl,
        },
        'triggeredAt': FieldValue.serverTimestamp(),
        'timestamp': FieldValue.serverTimestamp(),
        'notifiedUids': recipientUids,
      }).timeout(const Duration(seconds: 3), onTimeout: () {
        debugPrint('[SosCloud] ⏱️ Firestore write timed out after 3s (queued in local cache)');
      });

      debugPrint('[SosCloud] 🚨 Cloud SOS Alert logged in Firestore: $alertId');
      return alertId;
    } catch (e) {
      debugPrint('[SosCloud] ❌ Failed to dispatch cloud SOS: $e');
      return null;
    }
  }

  /// Marks an active SOS emergency alert as resolved.
  Future<void> resolveSosAlert(String alertId) async {
    try {
      await _firestore.collection('sos_alerts').doc(alertId).update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('[SosCloud] ✅ Alert marked as resolved: $alertId');
    } catch (e) {
      debugPrint('[SosCloud] Error resolving alert: $e');
    }
  }
}
