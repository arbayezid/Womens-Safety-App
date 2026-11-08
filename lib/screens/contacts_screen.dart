import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../services/contact_service.dart';
import '../services/contact_sync_service.dart';
import '../services/guardian_link_logic.dart';
import '../utils/auth_guard.dart';
import '../widgets/add_contact_dialog.dart';
import '../widgets/pending_requests_section.dart';
import 'package:url_launcher/url_launcher.dart';

/// Contacts screen — manage emergency and trusted contacts.
///
/// Provides live search, add contact modal with Bangladesh phone validation,
/// real-time persistence via [ContactService], delete confirmation,
/// and the Primary contact star (one primary, pinned to the top, texted first on SOS).
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

  /// Whether the one-time "tap the star" hint was already dismissed (or a primary was set).
  /// Starts true so the hint never flashes before the saved value is loaded.
  bool _primaryHintSeen = true;

  /// "People I Protect" entries with an add / stop-protecting call in flight.
  final Set<String> _busyProtectedUids = {};

  /// Contacts that are also people I protect (from the latest build), keyed by contact ID.
  Map<String, _ProtectedMatch> _protectedMatches = const {};

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
    ContactSyncService.instance.protectedPeopleNotifier.addListener(_onProtectedPeopleChanged);

    ContactSyncService.instance.initialize();
    _loadContacts();
    _subscribeToSyncedContacts();
    _loadPrimaryHintState();
  }

  // ── Primary contact ───────────────────────────────────────────────────────

  String get _primaryHintKey {
    final uid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
    return 'contacts_primary_hint_seen_${uid ?? 'guest'}';
  }

  Future<void> _loadPrimaryHintState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool(_primaryHintKey) ?? false;
      if (mounted) setState(() => _primaryHintSeen = seen);
    } catch (_) {}
  }

  Future<void> _setPrimaryHintSeen(bool seen) async {
    if (mounted) setState(() => _primaryHintSeen = seen);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_primaryHintKey, seen);
    } catch (_) {}
  }

  bool _isPrimary(ContactModel contact) =>
      ContactService.primaryOf(_contacts)?.id == contact.id;

  /// Star tap: makes [contact] the only Primary contact, or removes it when it already is.
  Future<void> _togglePrimary(ContactModel contact) async {
    await _applyPrimary(contact, makePrimary: !_isPrimary(contact));
  }

  Future<void> _applyPrimary(ContactModel contact, {required bool makePrimary}) async {
    HapticFeedback.selectionClick();
    final ok = await ContactService.instance
        .setPrimaryContact(makePrimary ? contact.id : null);
    if (!mounted) return;
    if (ok && makePrimary) unawaited(_setPrimaryHintSeen(true));
    _showPrimarySnack(
      ok
          ? (makePrimary
              ? '${contact.name} is now your primary contact'
              : '${contact.name} is no longer your primary contact')
          : 'Could not change your primary contact. Check your connection and try again.',
      success: ok,
    );
  }

  void _showPrimarySnack(String message, {required bool success}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(success ? Icons.star_rounded : Icons.error_outline_rounded,
              color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ],
      ),
      backgroundColor: success ? AppColors.primary : AppColors.sosRed,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: Duration(seconds: success ? 2 : 4),
    ));
  }

  /// Long-press menu on a contact card. [protectedPerson] is set when the current user also
  /// protects this contact; the menu then offers "Stop protecting".
  Future<void> _showContactMenu(ContactModel contact, {ProtectedPerson? protectedPerson}) async {
    HapticFeedback.mediumImpact();
    final bool isPrimary = _isPrimary(contact);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  contact.name,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
              ),
              ListTile(
                leading: Icon(isPrimary ? Icons.star_border_rounded : Icons.star_rounded,
                    color: AppColors.primary),
                title: Text(
                  isPrimary ? 'Remove as primary contact' : 'Set as primary contact',
                  style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: isPrimary
                    ? null
                    : Text('Gets your SOS alert and text first',
                        style: GoogleFonts.poppins(
                            fontSize: 11.5, color: AppColors.textSecondary)),
                onTap: () => Navigator.pop(ctx, 'primary'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: AppColors.primary),
                title: Text('Edit contact',
                    style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
              if (protectedPerson != null)
                _sheetTile(
                  ctx,
                  icon: Icons.remove_moderator_outlined,
                  color: AppColors.sosRed,
                  title: 'Stop protecting ${protectedPerson.name.split(' ').first}',
                  subtitle: 'You will no longer receive their SOS alerts',
                  value: 'stop',
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'primary') {
      await _applyPrimary(contact, makePrimary: !isPrimary);
    } else if (action == 'edit') {
      await _showEditPhoneDialog(contact);
    } else if (action == 'stop' && protectedPerson != null) {
      await _confirmStopProtecting(protectedPerson);
    }
  }

  @override
  void didUpdateWidget(ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When tab becomes active in IndexedStack, immediately refresh both contacts and requests
    if (!oldWidget.isActive && widget.isActive) {
      ContactSyncService.instance.initialize();
      _subscribeToSyncedContacts();
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
      setState(() {
        _contacts = ContactService.instance.contacts;
      });
    }
  }

  void _onProtectedPeopleChanged() {
    if (mounted) setState(() {});
  }

  /// People I protect who are also in my own contact list, keyed by that contact's ID.
  /// They get ONE card (the contact card) with a shield badge instead of a second card.
  Map<String, _ProtectedMatch> _protectedByContactId(List<ProtectedPerson> people) {
    final map = <String, _ProtectedMatch>{};
    for (final p in people) {
      final link = linkToProtectedPerson(p, _contacts);
      final contact = link.contact;
      if (contact != null) map[contact.id] = _ProtectedMatch(p, link.state);
    }
    return map;
  }

  void _subscribeToSyncedContacts() {
    _contactsSubscription?.cancel();
    _contactsSubscription =
        ContactSyncService.instance.streamSyncedContacts().listen((synced) {
      ContactService.instance.syncFromCloud(synced);
    }, onError: (err) {
      debugPrint('[ContactsScreen] synced contacts stream error: $err');
    });
  }

  @override
  void dispose() {
    ContactService.instance.contactsNotifier.removeListener(_onContactsChanged);
    ContactSyncService.instance.incomingRequestsNotifier.removeListener(_onIncomingRequestsChanged);
    ContactSyncService.instance.protectedPeopleNotifier.removeListener(_onProtectedPeopleChanged);
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
    final filtered = _filtered;
    final ContactModel? primary = ContactService.primaryOf(_contacts);
    final ContactModel? shownPrimary =
        primary != null && filtered.any((c) => c.id == primary.id) ? primary : null;
    final others = filtered.where((c) => c.id != primary?.id).toList();
    // Everyone except backup contacts gets the SOS straight away (all of them if only backups exist)
    final int regularCount = _contacts.where((c) => !c.isBackup).length;
    final int totalEmergencyCount = regularCount > 0 ? regularCount : _contacts.length;
    final bool showPrimaryHint = primary == null &&
        !_primaryHintSeen &&
        _searchQuery.trim().isEmpty &&
        others.isNotEmpty;

    final query = _searchQuery.trim().toLowerCase();
    final protectedPeople = ContactSyncService.instance.protectedPeopleNotifier.value;
    final protectedMatches = _protectedByContactId(protectedPeople);
    _protectedMatches = protectedMatches;
    final mergedUids = protectedMatches.values.map((m) => m.person.uid).toSet();
    final shownProtected = protectedPeople
        .where((p) => !mergedUids.contains(p.uid))
        .where((p) =>
            query.isEmpty ||
            p.name.toLowerCase().contains(query) ||
            p.email.toLowerCase().contains(query))
        .toList();

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
            _buildSOSBanner(totalEmergencyCount, primary),

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
                          // ── Incoming Guardian Requests (consent) ──────────────────
                          const PendingRequestsSection(),

                          // ── Primary contact, pinned to the top ────────────────────
                          if (shownPrimary != null) ...[
                            const _SectionLabel(label: 'Primary Contact'),
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _buildContactCard(shownPrimary, isPrimary: true),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (others.isNotEmpty) ...[
                            _SectionLabel(
                                label: primary == null
                                    ? 'Emergency Contacts (SOS)'
                                    : 'Other Emergency Contacts'),
                            const SizedBox(height: 10),
                            if (showPrimaryHint)
                              _PrimaryHint(onDismiss: () => _setPrimaryHintSeen(true)),
                            ...others.map((c) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _buildContactCard(c, isPrimary: false),
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

                          // ── People I Protect (they chose me as their guardian) ──────
                          // Anyone who is also my contact is shown once, above, with a shield.
                          if (protectedPeople.isNotEmpty &&
                              (shownProtected.isNotEmpty || query.isEmpty))
                            _PeopleIProtectSection(
                              people: shownProtected,
                              totalCount: protectedPeople.length,
                              alsoContactStates: protectedMatches.values.map((m) => m.state).toSet(),
                              myContacts: _contacts,
                              busyUids: _busyProtectedUids,
                              onTap: _onProtectedPersonTap,
                              onMenu: _showProtectedPersonMenu,
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

  Widget _buildContactCard(ContactModel c, {required bool isPrimary}) {
    final match = _protectedMatches[c.id];
    return _ContactCard(
      contact: c,
      isPrimary: isPrimary,
      protectState: match?.state,
      onTogglePrimary: () => _togglePrimary(c),
      onLongPress: () => _showContactMenu(c, protectedPerson: match?.person),
      onCall: () => makePhoneCall(c.phone),
      onMessage: () => openSMSApp(c.phone),
      onDelete: () => _confirmDelete(c, protectedPerson: match?.person),
      onUpgrade: () => _handleUpgrade(c),
      onEditPhone: () => _showEditPhoneDialog(c),
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

  Widget _buildSOSBanner(int count, ContactModel? primary) {
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
                  if (_contacts.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(primary != null ? Icons.star_rounded : Icons.star_border_rounded,
                            color: Colors.white, size: 13),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            primary != null
                                ? 'Primary: ${primary.name} (alerted first)'
                                : 'No primary contact yet. Tap the star on a contact.',
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
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
  ///
  /// [protectedPerson] is set when the removal starts from a "People I Protect" card: only the
  /// current user's own contact entry is removed, and the person stays in "People I Protect".
  Future<void> _confirmDelete(ContactModel contact, {ProtectedPerson? protectedPerson}) async {
    final bool fromProtected = protectedPerson != null;
    final bool isRequest = contact.isPending;
    final String who = contact.hasPhone ? '"${contact.name}" (${contact.phone})' : '"${contact.name}"';
    final String message = fromProtected
        ? (isRequest
            ? 'Cancel your guardian request to $who? You will still protect them and receive their SOS alerts.'
            : 'Remove $who from your emergency contacts? They will no longer receive your SOS alerts. '
                'You will still protect them and receive their SOS alerts.')
        : 'Are you sure you want to remove $who? They will no longer receive emergency alerts.';
    final String title =
        fromProtected ? (isRequest ? 'Cancel Request' : 'Remove Contact') : 'Delete Contact';
    final String confirmLabel = fromProtected ? (isRequest ? 'Cancel request' : 'Remove') : 'Delete';
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
                  title,
                  style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                ),
              ],
            ),
            content: Text(
              message,
              style: GoogleFonts.poppins(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(isRequest && fromProtected ? 'Keep' : 'Cancel',
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
                child: Text(confirmLabel,
                    style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ],
          ),
        );

        if (confirmed == true) {
          final bool wasPrimary = _isPrimary(contact);
          if (mounted) {
            setState(() {
              // _contacts is often the unmodifiable list from ContactService, so build a new
              // list instead of removing in place (removeWhere threw and aborted the delete).
              _contacts = _contacts
                  .where((c) => !(c.id == contact.id || (contact.contactUid != null && c.contactUid == contact.contactUid)))
                  .toList();
            });
          }
          // Permanently delete across Firestore (both directions) and local storage
          final removed = await ContactSyncService.instance.deleteSyncedContact(contact);
          // No primary any more: show the "tap the star" hint again
          if (removed && wasPrimary) unawaited(_setPrimaryHintSeen(false));
          await _loadContacts();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                removed
                    ? (fromProtected && isRequest
                        ? 'Request to ${contact.name} cancelled'
                        : fromProtected
                            ? '${contact.name} removed from your contacts. You still protect them.'
                            : '${contact.name} removed from contacts')
                    : 'Could not remove ${contact.name}. Check your connection and try again.',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            backgroundColor: removed ? AppColors.textPrimary : AppColors.sosRed,
            behavior: SnackBarBehavior.floating,
            shape: const StadiumBorder(),
            margin: const EdgeInsets.all(16),
            duration: Duration(seconds: removed ? 2 : 4),
          ));
        }
      },
    );
  }

  // ── People I Protect actions ───────────────────────────────────────────────

  /// Card tap: invite when not yet a contact, otherwise show the options.
  void _onProtectedPersonTap(ProtectedPerson person) {
    if (_busyProtectedUids.contains(person.uid)) return;
    final link = linkToProtectedPerson(person, _contacts);
    if (link.state == ProtectedLinkState.notAdded) {
      _confirmAddProtectedPerson(person);
    } else {
      _showProtectedPersonMenu(person);
    }
  }

  void _setProtectedBusy(String uid, bool busy) {
    if (!mounted) return;
    setState(() => busy ? _busyProtectedUids.add(uid) : _busyProtectedUids.remove(uid));
  }

  void _showResultSnack(String message, {required bool success, IconData? icon}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(icon ?? (success ? Icons.check_circle_rounded : Icons.error_outline_rounded),
              color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ],
      ),
      backgroundColor: success ? AppColors.actionGreen : AppColors.sosRed,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: Duration(seconds: success ? 3 : 4),
    ));
  }

  /// Yes / No modal: invite a protected person to become the user's emergency contact too.
  Future<void> _confirmAddProtectedPerson(ProtectedPerson person) async {
    HapticFeedback.selectionClick();
    String relationship = suggestReverseRelationship(person.relationship);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: AppColors.surface,
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.person_add_alt_1_rounded,
                    color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Add as Emergency Contact?',
                  style: GoogleFonts.poppins(
                      fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: GoogleFonts.poppins(
                        fontSize: 13, height: 1.45, color: AppColors.textSecondary),
                    children: [
                      const TextSpan(text: 'Do you want to add '),
                      TextSpan(
                        text: person.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                      const TextSpan(
                          text: ' as your emergency contact? They will get a request and, '
                              'once they accept, will receive your SOS alerts.'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '${person.name.split(' ').first} is your…',
                  style: GoogleFonts.poppins(
                      fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: reverseRelationshipOptions.map((rel) {
                    final selected = rel == relationship;
                    return ChoiceChip(
                      label: Text(rel),
                      selected: selected,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      labelStyle: GoogleFonts.poppins(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : AppColors.textPrimary,
                      ),
                      selectedColor: AppColors.primary,
                      backgroundColor: AppColors.background,
                      side: BorderSide(
                          color: selected
                              ? AppColors.primary
                              : AppColors.textSecondary.withValues(alpha: 0.25)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      onSelected: (_) => setDialogState(() => relationship = rel),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                Text(
                  'You will keep protecting ${person.name.split(' ').first} either way.',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('No',
                  style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Yes, add',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    _setProtectedBusy(person.uid, true);
    try {
      await ContactSyncService.instance
          .addProtectedPersonAsContact(person, relationship: relationship);
      _showResultSnack(
        'Request sent to ${person.name}. They become your emergency contact once they accept.',
        success: true,
        icon: Icons.send_rounded,
      );
      await _loadContacts();
    } catch (e) {
      _showResultSnack(e.toString().replaceAll('Exception: ', ''), success: false);
    } finally {
      _setProtectedBusy(person.uid, false);
    }
  }

  /// Options for a protected person: add / cancel / remove as my contact, and stop protecting.
  Future<void> _showProtectedPersonMenu(ProtectedPerson person) async {
    if (_busyProtectedUids.contains(person.uid)) return;
    HapticFeedback.mediumImpact();
    final link = linkToProtectedPerson(person, _contacts);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  person.name,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                      fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
              ),
              if (link.state == ProtectedLinkState.notAdded)
                _sheetTile(
                  ctx,
                  icon: Icons.person_add_alt_1_rounded,
                  color: AppColors.primary,
                  title: 'Add as my emergency contact',
                  subtitle: 'Sends them a request to receive your SOS alerts',
                  value: 'add',
                )
              else if (link.state == ProtectedLinkState.requestSent)
                _sheetTile(
                  ctx,
                  icon: Icons.cancel_schedule_send_rounded,
                  color: AppColors.actionOrange,
                  title: 'Cancel my request',
                  subtitle: 'They have not accepted yet',
                  value: 'remove',
                )
              else
                _sheetTile(
                  ctx,
                  icon: Icons.person_remove_alt_1_rounded,
                  color: AppColors.actionOrange,
                  title: 'Remove from my emergency contacts',
                  subtitle: 'They stop getting your alerts. You still protect them.',
                  value: 'remove',
                ),
              _sheetTile(
                ctx,
                icon: Icons.remove_moderator_outlined,
                color: AppColors.sosRed,
                title: 'Stop protecting ${person.name.split(' ').first}',
                subtitle: 'You will no longer receive their SOS alerts',
                value: 'stop',
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'add':
        await _confirmAddProtectedPerson(person);
      case 'remove':
        if (link.contact != null) await _confirmDelete(link.contact!, protectedPerson: person);
      case 'stop':
        await _confirmStopProtecting(person);
    }
  }

  Widget _sheetTile(
    BuildContext ctx, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String value,
  }) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title,
          style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color == AppColors.sosRed ? AppColors.sosRed : AppColors.textPrimary)),
      subtitle: Text(subtitle,
          style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary)),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  /// Removes a person from "People I Protect": the user leaves their guardian list.
  Future<void> _confirmStopProtecting(ProtectedPerson person) async {
    final link = linkToProtectedPerson(person, _contacts);
    final firstName = person.name.split(' ').first;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE5E5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.remove_moderator_outlined,
                  color: AppColors.sosRed, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Stop Protecting?',
                style: GoogleFonts.poppins(
                    fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        content: Text(
          'You will be removed from ${person.name}\'s emergency contacts and will no longer '
          'receive their SOS alerts or journey updates. $firstName can send you a new request later.'
          '${link.state == ProtectedLinkState.notAdded ? '' : '\n\n$firstName stays in your own emergency contacts.'}',
          style: GoogleFonts.poppins(fontSize: 13, height: 1.45, color: AppColors.textSecondary),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Stop protecting',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _setProtectedBusy(person.uid, true);
    final ok = await ContactSyncService.instance.stopProtecting(person);
    _setProtectedBusy(person.uid, false);
    _showResultSnack(
      ok
          ? 'You no longer protect ${person.name}'
          : 'Could not stop protecting ${person.name}. Check your connection and try again.',
      success: ok,
      icon: ok ? Icons.remove_moderator_outlined : null,
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
    final bool wasPrimary = _isPrimary(contact);
    bool wantPrimary = wasPrimary;

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
                        // A contact without a phone may still change only its Primary setting
                        if (!contact.hasPhone && wantPrimary != wasPrimary) return null;
                        return 'Please enter a valid phone number';
                      }
                      if (clean.length < 9) {
                        return 'Phone number is too short';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  StatefulBuilder(
                    builder: (context, setSwitchState) => SwitchListTile(
                      value: wantPrimary,
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: AppColors.primary,
                      secondary: Icon(
                        wantPrimary ? Icons.star_rounded : Icons.star_border_rounded,
                        color: wantPrimary ? AppColors.primary : AppColors.textSecondary,
                      ),
                      title: Text(
                        'Primary contact',
                        style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary),
                      ),
                      subtitle: Text(
                        'Gets your SOS alert and text first. Only one contact can be primary.',
                        style: GoogleFonts.poppins(
                            fontSize: 11.5, color: AppColors.textSecondary),
                      ),
                      onChanged: (val) => setSwitchState(() => wantPrimary = val),
                    ),
                  ),
                  const SizedBox(height: 12),
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
                        final bool hasNewPhone = phoneController.text.trim().isNotEmpty;
                        final newPhone = ContactSyncService.instance
                            .normalizePhone(phoneController.text.trim());
                        Navigator.pop(ctx);

                        if (hasNewPhone) {
                          // Start from the latest copy so a stale Primary flag is never written back
                          final latest = ContactService.instance.contacts
                                  .where((c) => c.id == contact.id)
                                  .firstOrNull ??
                              contact;
                          final updatedContact = latest.copyWith(phone: newPhone);
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
                        }

                        if (wantPrimary != wasPrimary) {
                          // Shows "{Name} is now your primary contact" (or the error)
                          await _applyPrimary(contact, makePrimary: wantPrimary);
                          _loadContacts();
                          return;
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
                        'Save',
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

/// A contact who is also someone the current user protects.
class _ProtectedMatch {
  final ProtectedPerson person;

  /// [ProtectedLinkState.added]: both sides protect each other (green shield).
  /// [ProtectedLinkState.requestSent]: the current user's request is still pending (orange).
  final ProtectedLinkState state;

  const _ProtectedMatch(this.person, this.state);
}

/// People who added the current user as their guardian. The current user receives their
/// alerts; each card also shows whether the person is one of the current user's own
/// emergency contacts, and lets the user add or remove them, or stop protecting them.
class _PeopleIProtectSection extends StatelessWidget {
  /// People to show here: those who are NOT also the current user's contacts.
  final List<ProtectedPerson> people;

  /// Everyone the current user protects, including those shown above as contacts.
  final int totalCount;

  /// Shield colours in use on contact cards above (people who are also contacts).
  final Set<ProtectedLinkState> alsoContactStates;
  final List<ContactModel> myContacts;
  final Set<String> busyUids;
  final ValueChanged<ProtectedPerson> onTap;
  final ValueChanged<ProtectedPerson> onMenu;

  const _PeopleIProtectSection({
    required this.people,
    required this.totalCount,
    required this.alsoContactStates,
    required this.myContacts,
    required this.busyUids,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(label: 'People I Protect ($totalCount)'),
          const SizedBox(height: 2),
          Text(
            people.isEmpty
                ? 'You receive their SOS alerts.'
                : 'You receive their SOS alerts. Tap a card to add them as your emergency contact too.',
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
          ),
          if (alsoContactStates.isNotEmpty) ...[
            const SizedBox(height: 6),
            _ShieldLegend(states: alsoContactStates),
          ],
          const SizedBox(height: 10),
          ...people.map((p) {
            final link = linkToProtectedPerson(p, myContacts);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProtectedPersonCard(
                person: p,
                link: link,
                busy: busyUids.contains(p.uid),
                onTap: () => onTap(p),
                onMenu: () => onMenu(p),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _ProtectedPersonCard extends StatelessWidget {
  final ProtectedPerson person;
  final ProtectedPersonLink link;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const _ProtectedPersonCard({
    required this.person,
    required this.link,
    required this.busy,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final bool added = link.state == ProtectedLinkState.added;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: busy ? null : onTap,
        onLongPress: busy ? null : onMenu,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: added
                  ? AppColors.actionGreen.withValues(alpha: 0.35)
                  : AppColors.primary.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration:
                        const BoxDecoration(color: Color(0xFFEDE7F6), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text(
                      person.initial,
                      style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryViolet),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 17,
                      height: 17,
                      decoration: BoxDecoration(
                          color: AppColors.primaryViolet,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.surface, width: 2)),
                      alignment: Alignment.center,
                      child: const Icon(Icons.shield_rounded, size: 9, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.name,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                          fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                    ),
                    if (person.email.isNotEmpty && person.email != person.name)
                      Text(
                        person.email,
                        overflow: TextOverflow.ellipsis,
                        style:
                            GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                      ),
                    if (person.relationship.isNotEmpty)
                      Text(
                        'Added you as: ${person.relationship}',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.primaryViolet),
                      ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: 'More options',
                  onPressed: onMenu,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shield badge on a contact's avatar when the current user also protects them.
/// Green: you protect each other. Orange: you protect them; your request to them is pending.
class _ProtectShieldBadge extends StatelessWidget {
  final ProtectedLinkState state;
  const _ProtectShieldBadge({required this.state});

  static Color colorFor(ProtectedLinkState state) =>
      state == ProtectedLinkState.added ? AppColors.actionGreen : AppColors.actionOrange;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 17,
      height: 17,
      decoration: BoxDecoration(
          color: colorFor(state),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.surface, width: 2)),
      alignment: Alignment.center,
      child: const Icon(Icons.shield_rounded, size: 9, color: Colors.white),
    );
  }
}

/// Explains the shield colours on contact avatars.
class _ShieldLegend extends StatelessWidget {
  final Set<ProtectedLinkState> states;
  const _ShieldLegend({required this.states});

  @override
  Widget build(BuildContext context) {
    Widget entry(ProtectedLinkState state, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, size: 13, color: _ProtectShieldBadge.colorFor(state)),
            const SizedBox(width: 4),
            Text(label,
                style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary)),
          ],
        );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        if (states.contains(ProtectedLinkState.added))
          entry(ProtectedLinkState.added, 'Shown above: you protect each other'),
        if (states.contains(ProtectedLinkState.requestSent))
          entry(ProtectedLinkState.requestSent, 'Shown above: your request is pending'),
      ],
    );
  }
}

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
  final bool isPrimary;

  /// Set when the current user also protects this contact (shield badge on the avatar).
  final ProtectedLinkState? protectState;
  final VoidCallback onTogglePrimary;
  final VoidCallback? onLongPress;
  final VoidCallback onCall, onMessage, onDelete;
  final VoidCallback? onUpgrade;
  final VoidCallback? onEditPhone;

  const _ContactCard({
    required this.contact,
    required this.isPrimary,
    this.protectState,
    required this.onTogglePrimary,
    this.onLongPress,
    required this.onCall,
    required this.onMessage,
    required this.onDelete,
    this.onUpgrade,
    this.onEditPhone,
  });

  @override
  Widget build(BuildContext context) {
    final colorStyle = _getColorForContact(contact, isPrimary: isPrimary);

    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: isPrimary
            ? Border.all(color: AppColors.primary.withValues(alpha: 0.55), width: 1.5)
            : null,
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
              if (isPrimary)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 17,
                    height: 17,
                    decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2)),
                    alignment: Alignment.center,
                    child: const Icon(Icons.star_rounded, size: 10, color: Colors.white),
                  ),
                ),
              // You also protect them: green = both ways, orange = your request is pending
              if (protectState != null)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: _ProtectShieldBadge(state: protectState!),
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
                    if (isPrimary) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: AppColors.primarySurface,
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          'PRIMARY',
                          style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                              color: AppColors.primary),
                        ),
                      ),
                    ],
                    if (contact.isBackup) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0xFFFEEDD8),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          'BACKUP',
                          style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: AppColors.actionOrange),
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
                    // Alert Channel Badges
                    if (contact.hasPhone)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: AppColors.successBackground,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '📱 SMS',
                          style: GoogleFonts.poppins(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.actionGreen,
                          ),
                        ),
                      ),
                    if (contact.isSynced)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEDE7F6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '🔔 App',
                          style: GoogleFonts.poppins(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryViolet,
                          ),
                        ),
                      ),
                    if (contact.isBackup)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEEDD8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '🛡️ Backup',
                          style: GoogleFonts.poppins(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.actionOrange,
                          ),
                        ),
                      ),
                    if (!contact.hasPhone && !contact.isSynced)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEEEE),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '⚠️ No alert channel',
                          style: GoogleFonts.poppins(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.sosRed,
                          ),
                        ),
                      ),
                    if (contact.isPending)
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
                                color: AppColors.actionOrange,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Star (Primary contact) above the actions: Sync, Call, Message, Edit, Delete
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _PrimaryStarButton(isPrimary: isPrimary, onPressed: onTogglePrimary),
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
        ],
      ),
      ),
    );
  }
}

/// Star toggle for the Primary contact: outlined when not primary, filled in the accent
/// colour when primary. 48x48 tap target.
class _PrimaryStarButton extends StatelessWidget {
  final bool isPrimary;
  final VoidCallback onPressed;
  const _PrimaryStarButton({required this.isPrimary, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: isPrimary ? 'Primary contact (tap to remove)' : 'Set as primary contact',
      isSelected: isPrimary,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: EdgeInsets.zero,
      iconSize: 28,
      icon: const Icon(Icons.star_border_rounded, color: AppColors.textSecondary),
      selectedIcon: const Icon(Icons.star_rounded, color: AppColors.primary),
    );
  }
}

/// One-time hint shown above the first contact card while no Primary contact is set.
/// The arrow points down at that card's star button.
class _PrimaryHint extends StatelessWidget {
  final VoidCallback onDismiss;
  const _PrimaryHint({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.star_border_rounded, color: AppColors.primary, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose your primary contact',
                      style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap the star on a contact. Your primary contact gets your SOS alert and '
                      'text first. Everyone else is still alerted.',
                      style: GoogleFonts.poppins(
                          fontSize: 11.5, height: 1.35, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onDismiss,
                child: Text('Got it',
                    style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w700, color: AppColors.primary)),
              ),
            ],
          ),
        ),
        // Card padding (10) + half the 48dp star button (24) - half this icon (11) = 23
        const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 23),
            child: Icon(Icons.arrow_downward_rounded, color: AppColors.primary, size: 22),
          ),
        ),
      ],
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

_AvatarColorPair _getColorForContact(ContactModel contact, {required bool isPrimary}) {
  if (isPrimary) {
    return _avatarPalette[0];
  }
  final index = contact.name.hashCode.abs() % _avatarPalette.length;
  return _avatarPalette[index];
}

