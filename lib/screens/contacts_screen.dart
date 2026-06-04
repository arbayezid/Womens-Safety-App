import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';

/// Contacts screen — manage emergency contacts.
/// Includes a search bar, a list of contacts with call/message actions,
/// and an "Add Contact" FAB-style button.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  final List<_ContactItem> _contacts = const [
    _ContactItem(
      name: 'Mom',
      phone: '+880 1711 000001',
      relation: 'Family',
      initial: 'M',
      color: Color(0xFFFFB3AE),
      textColor: AppColors.sosRed,
      isEmergency: true,
    ),
    _ContactItem(
      name: 'Riya Sharma',
      phone: '+880 1822 000002',
      relation: 'Best Friend',
      initial: 'R',
      color: Color(0xFFDDEEFD),
      textColor: AppColors.actionBlue,
      isEmergency: true,
    ),
    _ContactItem(
      name: 'Dad',
      phone: '+880 1933 000003',
      relation: 'Family',
      initial: 'D',
      color: Color(0xFFDFF5E3),
      textColor: AppColors.actionGreen,
      isEmergency: true,
    ),
    _ContactItem(
      name: 'Sadia Islam',
      phone: '+880 1744 000004',
      relation: 'Colleague',
      initial: 'S',
      color: Color(0xFFF0E6F9),
      textColor: AppColors.actionPurple,
      isEmergency: false,
    ),
    _ContactItem(
      name: 'Nusrat Jahan',
      phone: '+880 1655 000005',
      relation: 'Neighbour',
      initial: 'N',
      color: Color(0xFFFEEDD8),
      textColor: AppColors.actionOrange,
      isEmergency: false,
    ),
  ];

  List<_ContactItem> get _filtered {
    if (_searchQuery.isEmpty) return _contacts;
    return _contacts
        .where((c) =>
            c.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            c.phone.contains(_searchQuery))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final emergency = _filtered.where((c) => c.isEmergency).toList();
    final others = _filtered.where((c) => !c.isEmergency).toList();

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
            _buildSOSBanner(emergency.length),

            // ── Contacts list ────────────────────────────────────────
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                children: [
                  if (emergency.isNotEmpty) ...[
                    _SectionLabel(label: 'Emergency Contacts'),
                    const SizedBox(height: 10),
                    ...emergency.map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ContactCard(
                            item: c,
                            onCall: () => _onCall(c.name),
                            onMessage: () => _onMessage(c.name),
                            onDelete: () => _onDelete(c),
                          ),
                        )),
                    const SizedBox(height: 8),
                  ],
                  if (others.isNotEmpty) ...[
                    _SectionLabel(label: 'Other Contacts'),
                    const SizedBox(height: 10),
                    ...others.map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ContactCard(
                            item: c,
                            onCall: () => _onCall(c.name),
                            onMessage: () => _onMessage(c.name),
                            onDelete: () => _onDelete(c),
                          ),
                        )),
                  ],
                  if (_filtered.isEmpty)
                    _EmptyState(
                      icon: Icons.person_search_rounded,
                      message: 'No contacts found',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onAddContact,
        backgroundColor: AppColors.primary,
        icon:
            const Icon(Icons.person_add_rounded, color: Colors.white, size: 20),
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
          Text('Contacts',
              style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const Spacer(),
          Icon(Icons.contact_phone_rounded,
              color: AppColors.primary, size: 24),
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
          style: GoogleFonts.poppins(
              fontSize: 13, color: AppColors.textPrimary),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: 'Search contacts...',
            hintStyle: GoogleFonts.poppins(
                fontSize: 13, color: AppColors.textSecondary),
            icon: const Icon(Icons.search_rounded,
                color: AppColors.textSecondary, size: 20),
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
                  Text('$count Emergency Contacts',
                      style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                  Text('Alerted instantly when SOS is triggered',
                      style: GoogleFonts.poppins(
                          fontSize: 10,
                          color: Colors.white.withValues(alpha: 0.8))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.white, size: 22),
          ],
        ),
      ),
    );
  }

  void _onCall(String name) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('📞 Calling $name...',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      backgroundColor: AppColors.actionGreen,
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ));
  }

  void _onMessage(String name) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('💬 Messaging $name...',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      backgroundColor: AppColors.actionBlue,
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ));
  }

  void _onDelete(_ContactItem item) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${item.name} removed',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ));
  }

  void _onAddContact() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddContactSheet(),
    );
  }
}

// ─── Sub-widgets ────────────────────────────────────────────────────────────

class _ContactItem {
  final String name, phone, relation, initial;
  final Color color, textColor;
  final bool isEmergency;

  const _ContactItem({
    required this.name,
    required this.phone,
    required this.relation,
    required this.initial,
    required this.color,
    required this.textColor,
    required this.isEmergency,
  });
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
            letterSpacing: 0.3));
  }
}

class _ContactCard extends StatelessWidget {
  final _ContactItem item;
  final VoidCallback onCall, onMessage, onDelete;

  const _ContactCard({
    required this.item,
    required this.onCall,
    required this.onMessage,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
          // Avatar
          Stack(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: item.color,
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(item.initial,
                    style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: item.textColor)),
              ),
              if (item.isEmergency)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                        color: AppColors.sosRed,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppColors.surface, width: 2)),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(item.name,
                        style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 6),
                    if (item.isEmergency)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0xFFFFE5E5),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text('SOS',
                            style: GoogleFonts.poppins(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppColors.sosRed)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(item.phone,
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textSecondary)),
                Text(item.relation,
                    style: GoogleFonts.poppins(
                        fontSize: 10, color: item.textColor)),
              ],
            ),
          ),
          // Actions
          Row(
            children: [
              _ActionIconBtn(
                  icon: Icons.phone_rounded,
                  color: AppColors.actionGreen,
                  bg: AppColors.successBackground,
                  onTap: onCall),
              const SizedBox(width: 6),
              _ActionIconBtn(
                  icon: Icons.message_rounded,
                  color: AppColors.actionBlue,
                  bg: const Color(0xFFDDEEFD),
                  onTap: onMessage),
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

  const _ActionIconBtn(
      {required this.icon,
      required this.color,
      required this.bg,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 18),
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
            Icon(icon, size: 54, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(message,
                style: GoogleFonts.poppins(
                    fontSize: 14, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _AddContactSheet extends StatelessWidget {
  const _AddContactSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
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
            const SizedBox(height: 20),
            Text('Add Emergency Contact',
                style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 20),
            _SheetTextField(label: 'Full Name', icon: Icons.person_rounded),
            const SizedBox(height: 12),
            _SheetTextField(
                label: 'Phone Number',
                icon: Icons.phone_rounded,
                keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _SheetTextField(label: 'Relation', icon: Icons.favorite_rounded),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
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
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                    child: Text('Save',
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
    );
  }
}

class _SheetTextField extends StatelessWidget {
  final String label;
  final IconData icon;
  final TextInputType keyboardType;
  const _SheetTextField({
    required this.label,
    required this.icon,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14)),
      child: TextField(
        keyboardType: keyboardType,
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textPrimary),
        decoration: InputDecoration(
          border: InputBorder.none,
          labelText: label,
          labelStyle: GoogleFonts.poppins(
              fontSize: 12, color: AppColors.textSecondary),
          prefixIcon: Icon(icon, color: AppColors.primary, size: 18),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }
}
