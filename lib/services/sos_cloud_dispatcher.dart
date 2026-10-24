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
    List<String>? recipientEmails,
    List<String>? recipientUids,
    bool isDuress = false,
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

      // 2. Fetch and merge recipient emails and UIDs
      final List<String> resolvedEmails = [];
      final List<String> resolvedUids = [];

      if (recipientEmails != null) {
        for (final e in recipientEmails) {
          final norm = e.trim().toLowerCase();
          if (norm.isNotEmpty && !resolvedEmails.contains(norm)) {
            resolvedEmails.add(norm);
          }
        }
      }

      if (recipientUids != null) {
        for (final u in recipientUids) {
          final clean = u.trim();
          if (clean.isNotEmpty && !clean.startsWith('offline_') && !resolvedUids.contains(clean)) {
            resolvedUids.add(clean);
          }
        }
      }

      // If either list is empty, fetch from Firestore contacts
      if (resolvedEmails.isEmpty || resolvedUids.isEmpty) {
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
            if (email.isNotEmpty && !resolvedEmails.contains(email)) {
              resolvedEmails.add(email);
            }
            if (uid.isNotEmpty && !uid.startsWith('offline_') && !resolvedUids.contains(uid)) {
              resolvedUids.add(uid);
            }
          }
        } catch (e) {
          debugPrint('[SosCloud] Firestore contacts fetch notice: $e');
        }
      }

      // Also include any locally cached contacts
      if (resolvedEmails.isEmpty || resolvedUids.isEmpty) {
        try {
          final localContacts = await ContactService.instance.getContacts();
          for (final c in localContacts) {
            final email = c.email.toLowerCase().trim();
            if (email.isNotEmpty && !resolvedEmails.contains(email)) {
              resolvedEmails.add(email);
            }
            if (c.contactUid != null && c.contactUid!.isNotEmpty && !resolvedUids.contains(c.contactUid)) {
              resolvedUids.add(c.contactUid!);
            }
          }
        } catch (e) {
          debugPrint('[SosCloud] Local contacts fetch notice: $e');
        }
      }

      // Resolve any missing recipient UIDs from their emails in parallel
      if (resolvedEmails.isNotEmpty) {
        try {
          await Future.wait(
            resolvedEmails.map((email) async {
              try {
                var snap = await _firestore
                    .collection('users')
                    .where('email', isEqualTo: email)
                    .limit(1)
                    .get()
                    .timeout(const Duration(seconds: 2));
                if (snap.docs.isEmpty) {
                  snap = await _firestore
                      .collection('users')
                      .where('user_email', isEqualTo: email)
                      .limit(1)
                      .get()
                      .timeout(const Duration(seconds: 2));
                }
                if (snap.docs.isNotEmpty) {
                  final foundUid = snap.docs.first.id;
                  if (!resolvedUids.contains(foundUid)) {
                    resolvedUids.add(foundUid);
                  }
                }
              } catch (_) {}
            }),
          ).timeout(const Duration(seconds: 2), onTimeout: () => []);
        } catch (_) {}
      }

      debugPrint('[SosCloud] 👥 Recipient emails: $resolvedEmails | UIDs: $resolvedUids');

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
        'recipientEmails': resolvedEmails,
        'recipientUids': resolvedUids,
        'source': source,
        'isDuress': isDuress,
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
        'recentTrail': position != null
            ? [
                {
                  'latitude': latitude,
                  'longitude': longitude,
                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                }
              ]
            : [],
      }).timeout(const Duration(seconds: 3), onTimeout: () {
        debugPrint('[SosCloud] ⏱️ Firestore write timed out after 3s (queued in local cache)');
      });

      // Record initial event in events subcollection for Incident Room timeline
      try {
        await docRef.collection('events').add({
          'type': 'sos_triggered',
          'title': 'SOS Alert Dispatched',
          'description': 'Emergency alert triggered via $source',
          'actorName': senderName,
          'actorUid': user.uid,
          'timestamp': FieldValue.serverTimestamp(),
          'metadata': {
            'source': source,
            'isDuress': isDuress,
            'latitude': latitude,
            'longitude': longitude,
            'address': humanAddress,
          },
        }).timeout(const Duration(seconds: 2));
      } catch (eventErr) {
        debugPrint('[SosCloud] Event subcollection notice: $eventErr');
      }

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

      // Record resolution event in timeline
      try {
        await _firestore.collection('sos_alerts').doc(alertId).collection('events').add({
          'type': 'sos_resolved',
          'title': 'Emergency Resolved ("I\'m Safe")',
          'description': 'Alert was marked safe and live tracking stopped.',
          'actorName': _auth.currentUser?.displayName ?? 'Sender',
          'actorUid': _auth.currentUser?.uid,
          'timestamp': FieldValue.serverTimestamp(),
        }).timeout(const Duration(seconds: 2));
      } catch (_) {}
    } catch (e) {
      debugPrint('[SosCloud] Error resolving alert: $e');
    }
  }
}
