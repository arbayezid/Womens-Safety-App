import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../services/contact_service.dart';
import '../services/contact_sync_service.dart';
import '../utils/auth_guard.dart';
import '../widgets/add_contact_dialog.dart';
import '../widgets/pending_requests_section.dart';
import 'package:url_launcher/url_launcher.dart';

/// Contacts screen — manage emergency and trusted contacts.
///
/// Provides live search, add contact modal with Bangladesh phone validation,
/// real-time persistence via [ContactService], delete confirmation,
/// and primary SOS contact tagging.
class ContactsScreen extends StatefulWidget {
  final bool isActive;
  const ContactsScreen({super.key, this.isActive = true});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<ContactModel> _contacts = [];
  bool _isLoading = true;
  StreamSubscription<List<ContactModel>>? _contactsSubscription;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));

    // Bind to reactive ContactService cache
    _contacts = ContactService.instance.contacts;
    _isLoading = _contacts.isEmpty;
    ContactService.instance.contactsNotifier.addListener(_onContactsChanged);
    ContactSyncService.instance.incomingRequestsNotifier.addListener(_onIncomingRequestsChanged);

    _loadContacts();
    _subscribeToSyncedContacts();
  }

  @override
  void didUpdateWidget(ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When tab becomes active in IndexedStack, immediately refresh both contacts and requests
    if (!oldWidget.isActive && widget.isActive) {
      _loadContacts();
    }
  }

  void _onContactsChanged() {
    if (mounted) {
      setState(() {
        _contacts = ContactService.instance.contacts;
        _isLoading = false;
      });
    }
  }

  void _onIncomingRequestsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _subscribeToSyncedContacts() {
    _contactsSubscription?.cancel();
    _contactsSubscription =
        ContactSyncService.instance.streamSyncedContacts().listen((synced) {
      ContactService.instance.syncFromCloud(synced);
    });
  }

  @override
  void dispose() {
    ContactService.instance.contactsNotifier.removeListener(_onContactsChanged);
    ContactSyncService.instance.incomingRequestsNotifier.removeListener(_onIncomingRequestsChanged);
    _contactsSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Asynchronously fetches saved contacts and fresh incoming consent requests from cloud.
  Future<void> _loadContacts() async {
    final results = await Future.wait([
      ContactService.instance.getContacts(forceRefresh: true),
      ContactSyncService.instance.refreshIncomingRequests(),
    ]);
    if (mounted) {
      setState(() {
        _contacts = results[0] as List<ContactModel>;
        _isLoading = false;
      });
    }
  }

  /// Contacts filtered by user's search query (matches name, phone, or relationship).
  List<ContactModel> get _filtered {
    if (_searchQuery.trim().isEmpty) return _contacts;
    final query = _searchQuery.trim().toLowerCase();
    return _contacts
        .where((c) =>
            c.name.toLowerCase().contains(query) ||
            c.phone.contains(query) ||
            c.relationship.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final emergency = _filtered.where((c) => c.isPrimary).toList();
    final others = _filtered.where((c) => !c.isPrimary).toList();
    final int totalEmergencyCount = _contacts.where((c) => c.isPrimary).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────
            _buildHeader(),

            // ── Search bar ──────────────────────────────────────────
            _buildSearchBar(),

            // ── SOS count banner ────────────────────────────────────
            _buildSOSBanner(totalEmergencyCount),

            // ── Contacts list ────────────────────────────────────────
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    )
                  : RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: _loadContacts,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics()),
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 80),
                        children: [
                          // ── Incoming Mutual Consent Requests ──────────────────────
                          const PendingRequestsSection(),

                          if (emergency.isNotEmpty) ...[
                            const _SectionLabel(label: 'Emergency Contacts (SOS)'),
                            const SizedBox(height: 10),
                            ...emergency.map((c) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ContactCard(
                                    contact: c,
                                    onCall: () => makePhoneCall(c.phone),
                                    onMessage: () => openSMSApp(c.phone),
                                    onDelete: () => _confirmDelete(c),
                                    onUpgrade: () => _handleUpgrade(c),
                                    onEditPhone: () => _showEditPhoneDialog(c),
                                  ),
                                )),
                            const SizedBox(height: 8),
                          ],
                          if (others.isNotEmpty) ...[
                            const _SectionLabel(label: 'Other Contacts'),
                            const SizedBox(height: 10),
                            ...others.map((c) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ContactCard(
                                    contact: c,
                                    onCall: () => makePhoneCall(c.phone),
                                    onMessage: () => openSMSApp(c.phone),
                                    onDelete: () => _confirmDelete(c),
                                    onUpgrade: () => _handleUpgrade(c),
                                    onEditPhone: () => _showEditPhoneDialog(c),
                                  ),
                                )),
                          ],
                          if (_filtered.isEmpty && !_isLoading)
                            _EmptyState(
                              icon: _contacts.isEmpty
                                  ? Icons.person_off_rounded
                                  : Icons.person_search_rounded,
                              message: _contacts.isEmpty
                                  ? 'No contacts added yet.\nTap "Add Contact" to add emergency contacts.'
                                  : 'No contacts match "$_searchQuery"',
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onAddContact,
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.person_add_rounded, color: Colors.white, size: 20),
        label: Text(
          'Add Contact',
          style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
        ),
        elevation: 6,
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text(
            'Contacts',
            style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Reload Contacts',
            icon: const Icon(Icons.refresh_rounded, color: AppColors.primary, size: 24),
            onPressed: _loadContacts,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 3))
          ],
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (v) => setState(() => _searchQuery = v),
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textPrimary),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: 'Search contacts by name, phone or relation...',
            hintStyle: GoogleFonts.poppins(
                fontSize: 13, color: AppColors.textSecondary),
            icon: const Icon(Icons.search_rounded,
                color: AppColors.textSecondary, size: 20),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded,
                        color: AppColors.textSecondary, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildSOSBanner(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primary, AppColors.primaryLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4))
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text('SOS',
                  style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 1)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count Emergency Contact${count == 1 ? '' : 's'}',
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                  Text(
                    'Alerted instantly with GPS location when SOS is triggered',
                    style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
          ],
        ),
      ),
    );
  }

  /// Sanitizes phone numbers by stripping spaces, dashes, brackets, and non-numeric
  /// characters while preserving the leading '+' for international dial codes.
  String _sanitizePhoneNumber(String rawPhone) {
    final trimmed = rawPhone.trim();
    if (trimmed.isEmpty) return '';
    final hasPlus = trimmed.startsWith('+');
    final digitsOnly = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    return hasPlus ? '+$digitsOnly' : digitsOnly;
  }

  /// Launches the native Phone Dialer with [rawPhoneNumber].
  ///
  /// Uses [LaunchMode.externalApplication] so the system phone dialer opens directly.
  /// If the intent cannot be launched (e.g. Wi-Fi-only tablets), an error SnackBar is displayed.
  Future<void> makePhoneCall(String rawPhoneNumber) async {
    final sanitizedPhone = _sanitizePhoneNumber(rawPhoneNumber);
    if (sanitizedPhone.isEmpty) {
      _showLaunchError('Invalid phone number provided.');
      return;
    }

    final Uri uri = Uri(scheme: 'tel', path: sanitizedPhone);
    try {
      if (await canLaunchUrl(uri)) {
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!launched) {
          _showLaunchError('Could not launch phone dialer for $sanitizedPhone.');
        }
      } else {
        _showLaunchError(
          'Could not launch phone dialer. Telephony may not be supported on this device.',
        );
      }
    } catch (e) {
      _showLaunchError('Error opening phone dialer: $e');
    }
  }

  /// Launches the native SMS messaging app with [rawPhoneNumber] pre-set as recipient.
  ///
  /// Uses [LaunchMode.externalApplication] so the default SMS app opens directly.
  /// If launching fails, an error SnackBar is displayed to inform the user.
  Future<void> openSMSApp(String rawPhoneNumber) async {
    final sanitizedPhone = _sanitizePhoneNumber(rawPhoneNumber);
    if (sanitizedPhone.isEmpty) {
      _showLaunchError('Invalid phone number provided.');
      return;
    }

    final Uri uri = Uri(scheme: 'sms', path: sanitizedPhone);
    try {
      if (await canLaunchUrl(uri)) {
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!launched) {
          _showLaunchError('Could not launch SMS app for $sanitizedPhone.');
        }
      } else {
        _showLaunchError(
          'Could not launch SMS app. Messaging may not be supported on this device.',
        );
      }
    } catch (e) {
      _showLaunchError('Error opening SMS app: $e');
    }
  }

  /// Displays an informative error SnackBar when URL launching fails.
  void _showLaunchError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.sosRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Displays confirmation dialog and removes contact on confirmation.
  Future<void> _confirmDelete(ContactModel contact) async {
    await AuthGuard.run(
      context,
      actionName: 'manage emergency contacts',
      customSubtitle:
          'To modify or remove verified emergency contacts, please sign in with Google.',
      onAuthenticated: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: AppColors.surface,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFE5E5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_outline_rounded,
                      color: AppColors.sosRed, size: 22),
                ),
                const SizedBox(width: 12),
                Text(
                  'Delete Contact',
                  style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                ),
              ],
            ),
            content: Text(
              'Are you sure you want to remove "${contact.name}" (${contact.phone})? They will no longer receive emergency alerts.',
              style: GoogleFonts.poppins(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Cancel',
                    style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.sosRed,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Delete',
                    style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ],
          ),
        );

        if (confirmed == true) {
          // Permanently delete across Firestore (both directions) and local storage
          await ContactSyncService.instance.deleteSyncedContact(contact);
          await _loadContacts();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${contact.name} removed from contacts',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            backgroundColor: AppColors.textPrimary,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 2),
          ));
        }
      },
    );
  }

  void _onAddContact() {
    AuthGuard.run(
      context,
      actionName: 'add emergency contacts',
      customSubtitle:
          'To save and synchronize emergency contacts with live guardian alerts, please sign in with Google.',
      onAuthenticated: () async {
        final result = await AddContactDialog.show(context);
        if (result == true) {
          await _loadContacts();
        }
      },
    );
  }

  Future<void> _handleUpgrade(ContactModel contact) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Checking if ${contact.email} is registered on Woman Guard...'),
        duration: const Duration(seconds: 1),
      ),
    );
    try {
      final success = await ContactSyncService.instance.upgradeOfflineToSynced(contact);
      if (!mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Connection request sent to ${contact.email}! Waiting for consent.'),
            backgroundColor: AppColors.actionGreen,
          ),
        );
        await _loadContacts();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('User ${contact.email} is not yet registered. Offline SMS alerts remain active.'),
            backgroundColor: AppColors.actionOrange,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: AppColors.sosRed,
        ),
      );
    }
  }

  /// Displays bottom sheet dialog allowing the user to configure or edit an emergency mobile number.
  Future<void> _showEditPhoneDialog(ContactModel contact) async {
    final phoneController = TextEditingController(text: contact.phone);
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.successBackground,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.phone_rounded,
                            color: AppColors.actionGreen, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Set Emergency Phone',
                              style: GoogleFonts.poppins(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              'for ${contact.name}',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Emergency distress SMS with your live GPS location will be dispatched to this number when SOS is activated.',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    autofocus: true,
                    style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Mobile Phone Number',
                      hintText: 'e.g. 01712345678 or +8801...',
                      prefixIcon: const Icon(Icons.phone_outlined,
                          color: AppColors.actionGreen, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF8F9FA),
                    ),
                    validator: (val) {
                      final clean = (val ?? '').replaceAll(RegExp(r'\s+|-|\(|\)'), '');
                      if (clean.isEmpty) {
                        return 'Please enter a valid phone number';
                      }
                      if (clean.length < 9) {
                        return 'Phone number is too short';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;
                        final newPhone = ContactSyncService.instance
                            .normalizePhone(phoneController.text.trim());
                        Navigator.pop(ctx);

                        final updatedContact = contact.copyWith(phone: newPhone);
                        await ContactService.instance.updateContact(updatedContact);

                        // Persist to Firestore subcollection if authenticated
                        if (Firebase.apps.isNotEmpty) {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            await FirebaseFirestore.instance
                                .collection('users')
                                .doc(user.uid)
                                .collection('contacts')
                                .doc(contact.id)
                                .set({
                              'phone': newPhone,
                              'contact_optional_phone': newPhone,
                            }, SetOptions(merge: true));
                          }
                        }

                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded,
                                    color: Colors.white),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Emergency phone updated for ${contact.name}!',
                                    style: GoogleFonts.poppins(
                                        fontWeight: FontWeight.w500,
                                        fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                            backgroundColor: AppColors.actionGreen,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        );
                        _loadContacts();
                      },
                      child: Text(
                        'Save Phone Number',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Sub-widgets ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: GoogleFonts.poppins(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
          letterSpacing: 0.3),
    );
  }
}

class _ContactCard extends StatelessWidget {
  final ContactModel contact;
  final VoidCallback onCall, onMessage, onDelete;
  final VoidCallback? onUpgrade;
  final VoidCallback? onEditPhone;

  const _ContactCard({
    required this.contact,
    required this.onCall,
    required this.onMessage,
    required this.onDelete,
    this.onUpgrade,
    this.onEditPhone,
  });

  @override
  Widget build(BuildContext context) {
    final colorStyle = _getColorForContact(contact);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3))
        ],
      ),
      child: Row(
        children: [
          // Avatar with initial
          Stack(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: colorStyle.bg,
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  contact.initial,
                  style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorStyle.text),
                ),
              ),
              if (contact.isPrimary)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                        color: AppColors.sosRed,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2)),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        contact.name,
                        style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (contact.isPrimary) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0xFFFFE5E5),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          'SOS',
                          style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: AppColors.sosRed),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                if (contact.email.isNotEmpty)
                  Text(
                    contact.email,
                    style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primaryViolet),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (contact.hasPhone)
                  Text(
                    contact.phone,
                    style: GoogleFonts.poppins(
                        fontSize: 10.5, color: AppColors.textSecondary),
                  )
                else if (onEditPhone != null)
                  GestureDetector(
                    onTap: onEditPhone,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.add_call, size: 12, color: AppColors.actionOrange),
                          const SizedBox(width: 4),
                          Text(
                            '+ Add phone for SMS',
                            style: GoogleFonts.poppins(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.actionOrange,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 3),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 5,
                  runSpacing: 2,
                  children: [
                    Text(
                      contact.relationship,
                      style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: colorStyle.text),
                    ),
                    // Sync Status Badge
                    if (contact.isSynced)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: AppColors.successBackground,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.verified_rounded, size: 10, color: AppColors.actionGreen),
                            const SizedBox(width: 3),
                            Text(
                              'Synced App User',
                              style: GoogleFonts.poppins(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.actionGreen),
                            ),
                          ],
                        ),
                      )
                    else if (contact.isPending)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF9E6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.hourglass_top_rounded, size: 10, color: AppColors.actionOrange),
                            const SizedBox(width: 3),
                            Text(
                              'Sync Pending',
                              style: GoogleFonts.poppins(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.actionOrange),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEF2F6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.sms_outlined, size: 10, color: AppColors.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              contact.hasPhone ? 'Offline SMS' : 'Email Only',
                              style: GoogleFonts.poppins(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Actions: Call, Message, Sync, Delete
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!contact.isSynced && !contact.isPending && contact.email.isNotEmpty && onUpgrade != null) ...[
                _ActionIconBtn(
                  icon: Icons.sync_rounded,
                  color: AppColors.primaryViolet,
                  bg: const Color(0xFFEDE7F6),
                  onTap: onUpgrade!,
                ),
                const SizedBox(width: 4),
              ],
              if (contact.hasPhone) ...[
                _ActionIconBtn(
                  icon: Icons.phone_rounded,
                  color: AppColors.actionGreen,
                  bg: AppColors.successBackground,
                  onTap: onCall,
                ),
                const SizedBox(width: 4),
                _ActionIconBtn(
                  icon: Icons.message_rounded,
                  color: AppColors.actionBlue,
                  bg: const Color(0xFFDDEEFD),
                  onTap: onMessage,
                ),
                const SizedBox(width: 4),
              ],
              if (onEditPhone != null) ...[
                _ActionIconBtn(
                  icon: Icons.edit_outlined,
                  color: AppColors.primary,
                  bg: const Color(0xFFEDE7F6),
                  onTap: onEditPhone!,
                ),
                const SizedBox(width: 4),
              ],
              _ActionIconBtn(
                icon: Icons.delete_outline_rounded,
                color: AppColors.sosRed,
                bg: const Color(0xFFFFE5E5),
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionIconBtn extends StatelessWidget {
  final IconData icon;
  final Color color, bg;
  final VoidCallback onTap;

  const _ActionIconBtn({
    required this.icon,
    required this.color,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 15),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            Icon(icon,
                size: 54, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dynamic avatar color generator to maintain sleek pastel aesthetics
class _AvatarColorPair {
  final Color bg;
  final Color text;
  const _AvatarColorPair(this.bg, this.text);
}

const List<_AvatarColorPair> _avatarPalette = [
  _AvatarColorPair(Color(0xFFFFB3AE), AppColors.sosRed),
  _AvatarColorPair(Color(0xFFDDEEFD), AppColors.actionBlue),
  _AvatarColorPair(Color(0xFFDFF5E3), AppColors.actionGreen),
  _AvatarColorPair(Color(0xFFF0E6F9), AppColors.actionPurple),
  _AvatarColorPair(Color(0xFFFEEDD8), AppColors.actionOrange),
];

_AvatarColorPair _getColorForContact(ContactModel contact) {
  if (contact.isPrimary) {
    return _avatarPalette[0];
  }
  final index = contact.name.hashCode.abs() % _avatarPalette.length;
  return _avatarPalette[index];
}

