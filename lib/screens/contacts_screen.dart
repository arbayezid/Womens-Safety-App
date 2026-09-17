import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../services/contact_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Contacts screen — manage emergency and trusted contacts.
///
/// Provides live search, add contact modal with Bangladesh phone validation,
/// real-time persistence via [ContactService], delete confirmation,
/// and primary SOS contact tagging.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<ContactModel> _contacts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Asynchronously fetches saved contacts from [ContactService].
  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    final loaded = await ContactService.instance.getContacts();
    if (mounted) {
      setState(() {
        _contacts = loaded;
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
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
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
      final success = await ContactService.instance.deleteContact(contact.id);
      if (success) {
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
    }
  }

  void _onAddContact() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddContactSheet(),
    );

    if (result == true) {
      await _loadContacts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ New contact added successfully!',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.successForeground,
        behavior: SnackBarBehavior.floating,
        shape: const StadiumBorder(),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ));
    }
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

  const _ContactCard({
    required this.contact,
    required this.onCall,
    required this.onMessage,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorStyle = _getColorForContact(contact);

    return Container(
      padding: const EdgeInsets.all(14),
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
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: colorStyle.bg,
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  contact.initial,
                  style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorStyle.text),
                ),
              ),
              if (contact.isPrimary)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                        color: AppColors.sosRed,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2)),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
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
                Text(
                  contact.phone,
                  style: GoogleFonts.poppins(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
                Text(
                  contact.relationship,
                  style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: colorStyle.text),
                ),
              ],
            ),
          ),
          // Actions: Call, Message, Delete
          Row(
            children: [
              _ActionIconBtn(
                icon: Icons.phone_rounded,
                color: AppColors.actionGreen,
                bg: AppColors.successBackground,
                onTap: onCall,
              ),
              const SizedBox(width: 6),
              _ActionIconBtn(
                icon: Icons.message_rounded,
                color: AppColors.actionBlue,
                bg: const Color(0xFFDDEEFD),
                onTap: onMessage,
              ),
              const SizedBox(width: 6),
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
        width: 34,
        height: 34,
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 17),
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
  return _avatarPalette[index == 0 ? 1 : index];
}

/// Modal Bottom Sheet for adding a new Contact with form validation and persistence.
class _AddContactSheet extends StatefulWidget {
  const _AddContactSheet();

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _relationController = TextEditingController(text: 'Family');
  bool _isPrimary = true;
  bool _isSubmitting = false;

  final List<String> _relationPresets = [
    'Family',
    'Best Friend',
    'Friend',
    'Colleague',
    'Neighbour',
    'Other'
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _relationController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      // Normalize Bangladesh phone number format
      String rawPhone = _phoneController.text.trim().replaceAll(RegExp(r'[\s\-]'), '');
      if (rawPhone.startsWith('01')) {
        rawPhone = '+88$rawPhone';
      }

      final newContact = ContactModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: _nameController.text.trim(),
        phone: rawPhone,
        relationship: _relationController.text.trim(),
        isPrimary: _isPrimary,
      );

      final success = await ContactService.instance.addContact(newContact);
      if (mounted) {
        Navigator.pop(context, success);
      }
    } catch (e) {
      debugPrint('Error saving contact: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Add Emergency Contact',
                style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Saved contacts are stored locally and notified during SOS triggers.',
                style: GoogleFonts.poppins(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),

              // Full Name field
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                style: GoogleFonts.poppins(
                    fontSize: 13, color: AppColors.textPrimary),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Contact name is required';
                  }
                  if (val.trim().length < 2) {
                    return 'Name must be at least 2 characters';
                  }
                  return null;
                },
                decoration: _buildInputDecoration(
                  label: 'Full Name',
                  hint: 'e.g. Mom, Riya Sharma',
                  icon: Icons.person_rounded,
                ),
              ),
              const SizedBox(height: 14),

              // Phone Number field with Bangladesh regex validation
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: GoogleFonts.poppins(
                    fontSize: 13, color: AppColors.textPrimary),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Phone number is required';
                  }
                  final clean = val.trim().replaceAll(RegExp(r'[\s\-]'), '');
                  // Regex validates BD formats like +8801XXXXXXXXX or 01XXXXXXXXX
                  final bdRegex = RegExp(r'^(\+8801|01)[3-9]\d{8}$');
                  if (!bdRegex.hasMatch(clean)) {
                    return 'Enter valid BD number (e.g. 01712345678 or +8801712345678)';
                  }
                  return null;
                },
                decoration: _buildInputDecoration(
                  label: 'Phone Number (Bangladesh)',
                  hint: 'e.g. +8801711000001 or 01711000001',
                  icon: Icons.phone_rounded,
                ),
              ),
              const SizedBox(height: 14),

              // Relationship input field
              TextFormField(
                controller: _relationController,
                style: GoogleFonts.poppins(
                    fontSize: 13, color: AppColors.textPrimary),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Relationship is required';
                  }
                  return null;
                },
                decoration: _buildInputDecoration(
                  label: 'Relationship',
                  hint: 'e.g. Family, Sister, Friend',
                  icon: Icons.favorite_rounded,
                ),
              ),
              const SizedBox(height: 10),

              // Relationship quick presets
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: _relationPresets.map((preset) {
                    final isSelected = _relationController.text == preset;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          preset,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                            color: isSelected ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: AppColors.primary,
                        backgroundColor: AppColors.background,
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _relationController.text = preset);
                          }
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 14),

              // SOS Primary Toggle Switch
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _isPrimary
                      ? const Color(0xFFFFE5E5).withValues(alpha: 0.6)
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isPrimary ? AppColors.sosRed.withValues(alpha: 0.4) : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: _isPrimary ? AppColors.sosRed : AppColors.textSecondary,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SOS Emergency Priority',
                            style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _isPrimary ? AppColors.sosRed : AppColors.textPrimary),
                          ),
                          Text(
                            'Sends emergency SMS automatically when SOS is pressed',
                            style: GoogleFonts.poppins(
                                fontSize: 10, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _isPrimary,
                      activeThumbColor: AppColors.sosRed,
                      onChanged: (val) => setState(() => _isPrimary = val),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSubmitting ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.textSecondary),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text('Cancel',
                          style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isSubmitting ? null : _handleSave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 0,
                      ),
                      child: _isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text('Save Contact',
                              style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _buildInputDecoration({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      filled: true,
      fillColor: AppColors.background,
      labelText: label,
      hintText: hint,
      labelStyle: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
      hintStyle: GoogleFonts.poppins(
          fontSize: 12, color: AppColors.textSecondary.withValues(alpha: 0.6)),
      prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.sosRed, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}
