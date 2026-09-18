import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/user_profile_model.dart';
import '../services/auth_service.dart';

/// Profile screen — user info, stats, activity history, and account options.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openEditProfileModal(BuildContext context, UserProfile profile) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EditProfileBottomSheet(initialProfile: profile),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserProfile>(
      valueListenable: AuthService.instance.profileNotifier,
      builder: (context, profile, __) {
        return Scaffold(
          backgroundColor: AppColors.background,
          body: NestedScrollView(
            headerSliverBuilder: (_, __) => [_buildSliverAppBar(context, profile)],
            body: Column(
              children: [
                // ── Tab bar ─────────────────────────────────────────────
                _buildTabBar(),
                // ── Tab views ───────────────────────────────────────────
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOverviewTab(profile),
                      _buildActivityTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSliverAppBar(BuildContext context, UserProfile profile) {
    return SliverAppBar(
      expandedHeight: 300,
      pinned: true,
      backgroundColor: AppColors.primary,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        background: _buildProfileHeader(profile),
      ),
      title: Text('Profile',
          style: GoogleFonts.poppins(
              fontWeight: FontWeight.w700, color: Colors.white, fontSize: 18)),
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_rounded, color: Colors.white),
          tooltip: 'Edit Profile',
          onPressed: () => _openEditProfileModal(context, profile),
        ),
      ],
    );
  }

  Widget _buildProfileHeader(UserProfile profile) {
    final photoUrl = AuthService.instance.photoUrl;
    final displayName = profile.name.isNotEmpty ? profile.name : AuthService.instance.displayName;
    final initials = profile.initials;
    final email = AuthService.instance.email;
    final isAuth = AuthService.instance.isAuthenticated;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, Color(0xFF7B72DB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 50),
            // Avatar with edit badge
            GestureDetector(
              onTap: () => _openEditProfileModal(context, profile),
              child: Stack(
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.25),
                      border: Border.all(color: Colors.white, width: 3),
                      image: photoUrl != null
                          ? DecorationImage(
                              image: NetworkImage(photoUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 16,
                            offset: const Offset(0, 4))
                      ],
                    ),
                    alignment: Alignment.center,
                    child: photoUrl == null
                        ? Text(initials,
                            style: GoogleFonts.poppins(
                                fontSize: 36,
                                fontWeight: FontWeight.bold,
                                color: Colors.white))
                        : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                          color: isAuth
                              ? AppColors.actionOrange
                              : AppColors.textSecondary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2)),
                      alignment: Alignment.center,
                      child: const Icon(
                          Icons.edit_rounded,
                          color: Colors.white,
                          size: 14),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            Text(displayName,
                style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),

            const SizedBox(height: 4),

            Text(
                profile.phone.isNotEmpty
                    ? profile.phone
                    : (email ??
                        (isAuth
                            ? '+880 1XXXXXXX'
                            : 'Explore Mode • Not logged in')),
                style: GoogleFonts.poppins(
                    fontSize: 13, color: Colors.white.withValues(alpha: 0.85))),

            const SizedBox(height: 6),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isAuth
                            ? AppColors.successForeground
                            : AppColors.actionOrange),
                  ),
                  const SizedBox(width: 6),
                  Text(
                      isAuth
                          ? 'Google Account: Active'
                          : 'Guest Mode: Tap to Sign In',
                      style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: AppColors.surface,
      child: TabBar(
        controller: _tabController,
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.primary,
        indicatorWeight: 3,
        labelStyle:
            GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w400),
        tabs: const [
          Tab(text: 'Overview'),
          Tab(text: 'Activity'),
        ],
      ),
    );
  }

  Widget _buildOverviewTab(UserProfile profile) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Stats row ──────────────────────────────────────────────
          _buildStatsRow(),

          const SizedBox(height: 20),

          // ── Personal info ───────────────────────────────────────────
          _buildInfoSection(profile),

          const SizedBox(height: 20),

          // ── Safety score ────────────────────────────────────────────
          _buildSafetyScore(),

          const SizedBox(height: 20),

          // ── Account actions ─────────────────────────────────────────
          _buildAccountActions(),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    const stats = [
      _StatItem(value: '3', label: 'Contacts', icon: Icons.group_rounded),
      _StatItem(
          value: '12',
          label: 'Alerts Sent',
          icon: Icons.notifications_active_rounded),
      _StatItem(value: '98%', label: 'Safe Score', icon: Icons.shield_rounded),
    ];

    return Row(
      children: stats
          .map((s) => Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: s == stats.last ? 0 : 12),
                  child: _StatCard(item: s),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildInfoSection(UserProfile profile) {
    final isAuth = AuthService.instance.isAuthenticated;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Personal Info',
                  style: GoogleFonts.poppins(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const Spacer(),
              GestureDetector(
                onTap: () => _openEditProfileModal(context, profile),
                child: Text('Edit',
                    style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _InfoRow(
              icon: Icons.person_rounded,
              label: 'Full Name',
              value: profile.name.isNotEmpty ? profile.name : 'Guest'),
          _InfoRow(
              icon: Icons.phone_rounded,
              label: 'Phone',
              value: profile.phone.isNotEmpty
                  ? profile.phone
                  : 'Tap Edit to add phone'),
          _InfoRow(
              icon: Icons.email_rounded,
              label: 'Email',
              value: profile.email.isNotEmpty
                  ? profile.email
                  : (isAuth ? 'Not connected' : 'Guest Mode')),
          _InfoRow(
              icon: Icons.bloodtype_rounded,
              label: 'Blood Group',
              value: profile.bloodGroup.isNotEmpty
                  ? profile.bloodGroup
                  : 'Not set'),
          _InfoRow(
              icon: Icons.location_city_rounded,
              label: 'City',
              value: profile.city.isNotEmpty ? profile.city : 'Not set'),
          _InfoRow(
              icon: Icons.cake_rounded,
              label: 'Date of Birth',
              value: profile.dob.isNotEmpty ? profile.dob : 'Not set',
              isLast: profile.emergencyNote.trim().isEmpty),
          if (profile.emergencyNote.trim().isNotEmpty)
            _InfoRow(
              icon: Icons.health_and_safety_rounded,
              label: 'Medical / Emergency Notes',
              value: profile.emergencyNote.trim(),
              isLast: true,
            ),
        ],
      ),
    );
  }

  Widget _buildSafetyScore() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFDFF5E3), Color(0xFFB8E6C4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 70,
                height: 70,
                child: CircularProgressIndicator(
                  value: 0.98,
                  backgroundColor:
                      AppColors.successForeground.withValues(alpha: 0.2),
                  color: AppColors.successForeground,
                  strokeWidth: 6,
                ),
              ),
              Text('98%',
                  style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.successForeground)),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Safety Score',
                    style: GoogleFonts.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 4),
                Text(
                    'Excellent! Your device is connected, 3 contacts set up and safety features enabled.',
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Account',
            style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary)),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 3))
              ]),
          child: Column(
            children: [
              if (!AuthService.instance.isAuthenticated) ...[
                _AccountAction(
                  icon: Icons.login_rounded,
                  iconColor: AppColors.primary,
                  iconBg: AppColors.primarySurface,
                  label: 'Sign in with Google',
                  onTap: () async {
                    final res = await AuthService.instance.signInWithGoogle();
                    if (res.isSuccess && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content:
                              Text('✅ Successfully signed in with Google!'),
                          backgroundColor: AppColors.successForeground,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(height: 1, color: AppColors.background)),
              ],
              _AccountAction(
                icon: Icons.edit_note_rounded,
                iconColor: AppColors.actionBlue,
                iconBg: const Color(0xFFDDEEFD),
                label: 'Edit Safety Details',
                onTap: () => _openEditProfileModal(
                    context, AuthService.instance.currentProfile),
              ),
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(height: 1, color: AppColors.background)),
              _AccountAction(
                icon: Icons.backup_rounded,
                iconColor: AppColors.actionPurple,
                iconBg: const Color(0xFFF0E6F9),
                label: 'Backup Data',
                onTap: () => _showSnack('Backup Data'),
              ),
              if (AuthService.instance.isAuthenticated) ...[
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(height: 1, color: AppColors.background)),
                _AccountAction(
                  icon: Icons.logout_rounded,
                  iconColor: AppColors.sosRed,
                  iconBg: const Color(0xFFFFE5E5),
                  label: 'Log Out',
                  onTap: _confirmLogout,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Log Out',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        content: Text(
            'Are you sure you want to log out? You will be switched to Guest Mode.',
            style: GoogleFonts.poppins(
                fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await AuthService.instance.signOut();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logged out. Switched to Guest Mode.'),
                  backgroundColor: AppColors.textPrimary,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sosRed,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: Text('Log Out',
                style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityTab() {
    const activities = [
      _ActivityLog(
        icon: Icons.notifications_active_rounded,
        color: AppColors.sosRed,
        bg: Color(0xFFFFE5E5),
        title: 'SOS Alert Triggered',
        subtitle: 'Notified 3 emergency contacts',
        time: '2 hours ago',
      ),
      _ActivityLog(
        icon: Icons.location_on_rounded,
        color: AppColors.actionGreen,
        bg: Color(0xFFDFF5E3),
        title: 'Location Shared',
        subtitle: 'Shared with Mom and Riya',
        time: 'Yesterday, 9:30 PM',
      ),
      _ActivityLog(
        icon: Icons.bluetooth_connected_rounded,
        color: AppColors.actionBlue,
        bg: Color(0xFFDDEEFD),
        title: 'ESP32 Connected',
        subtitle: 'Device synced successfully',
        time: 'Yesterday, 8:15 AM',
      ),
      _ActivityLog(
        icon: Icons.mic_rounded,
        color: AppColors.actionOrange,
        bg: Color(0xFFFEEDD8),
        title: 'Voice Activation',
        subtitle: '"Help" keyword detected',
        time: '3 days ago',
      ),
      _ActivityLog(
        icon: Icons.phone_in_talk_rounded,
        color: AppColors.actionPurple,
        bg: Color(0xFFF0E6F9),
        title: 'Fake Call Used',
        subtitle: 'Exited unsafe situation',
        time: '3 days ago',
      ),
      _ActivityLog(
        icon: Icons.campaign_rounded,
        color: AppColors.actionOrange,
        bg: Color(0xFFFEEDD8),
        title: 'Loud Siren Activated',
        subtitle: 'Active for 15 seconds',
        time: '5 days ago',
      ),
    ];

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        Text('Recent Activity',
            style: GoogleFonts.poppins(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 12),
        ...activities.map((a) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ActivityCard(log: a),
            )),
      ],
    );
  }

  void _showSnack(String label) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$label tapped',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 1),
    ));
  }
}

/// Interactive Bottom Sheet for Editing Profile and Saving Permanently.
class _EditProfileBottomSheet extends StatefulWidget {
  final UserProfile initialProfile;
  const _EditProfileBottomSheet({required this.initialProfile});

  @override
  State<_EditProfileBottomSheet> createState() =>
      _EditProfileBottomSheetState();
}

class _EditProfileBottomSheetState extends State<_EditProfileBottomSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _cityController;
  late final TextEditingController _dobController;
  late final TextEditingController _notesController;
  late String _selectedBloodGroup;
  bool _isSaving = false;

  static const List<String> _bloodGroups = [
    'A+',
    'A-',
    'B+',
    'B-',
    'O+',
    'O-',
    'AB+',
    'AB-'
  ];

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.initialProfile.name);
    _phoneController =
        TextEditingController(text: widget.initialProfile.phone);
    _cityController =
        TextEditingController(text: widget.initialProfile.city);
    _dobController =
        TextEditingController(text: widget.initialProfile.dob);
    _notesController =
        TextEditingController(text: widget.initialProfile.emergencyNote);
    _selectedBloodGroup =
        _bloodGroups.contains(widget.initialProfile.bloodGroup)
            ? widget.initialProfile.bloodGroup
            : 'B+';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _cityController.dispose();
    _dobController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(1998, 1, 1),
      firstDate: DateTime(1940),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: AppColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      setState(() {
        _dobController.text =
            '${months[picked.month - 1]} ${picked.day}, ${picked.year}';
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final updated = widget.initialProfile.copyWith(
      name: _nameController.text.trim(),
      phone: _phoneController.text.trim(),
      city: _cityController.text.trim(),
      dob: _dobController.text.trim(),
      bloodGroup: _selectedBloodGroup,
      emergencyNote: _notesController.text.trim(),
    );

    final success = await AuthService.instance.updateProfile(updated);

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Profile updated and saved permanently!'),
          backgroundColor: AppColors.successForeground,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update profile. Please try again.'),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        left: 20,
        right: 20,
        top: 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              // Title Header
              Row(
                children: [
                  Text(
                    'Edit Profile 📝',
                    style: GoogleFonts.poppins(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                'Personal & emergency safety info will be saved permanently to your account.',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),

              // Full Name
              TextFormField(
                controller: _nameController,
                style: GoogleFonts.poppins(fontSize: 14),
                decoration: _inputDecoration(
                  label: 'Full Name',
                  icon: Icons.person_outline_rounded,
                  hint: 'e.g. Fatima Rahman',
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),

              // Phone Number
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: GoogleFonts.poppins(fontSize: 14),
                decoration: _inputDecoration(
                  label: 'Phone Number',
                  icon: Icons.phone_outlined,
                  hint: '+880 1XXXXXXXXX',
                ),
              ),
              const SizedBox(height: 14),

              // Blood Group & City Row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Blood Group dropdown
                  Expanded(
                    flex: 1,
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedBloodGroup,
                      decoration: _inputDecoration(
                        label: 'Blood',
                        icon: Icons.bloodtype_outlined,
                      ),
                      items: _bloodGroups
                          .map((bg) => DropdownMenuItem(
                                value: bg,
                                child: Text(bg,
                                    style: GoogleFonts.poppins(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _selectedBloodGroup = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  // City
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _cityController,
                      style: GoogleFonts.poppins(fontSize: 14),
                      decoration: _inputDecoration(
                        label: 'City / District',
                        icon: Icons.location_city_outlined,
                        hint: 'Dhaka, Bangladesh',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Date of Birth
              TextFormField(
                controller: _dobController,
                readOnly: true,
                onTap: _pickDate,
                style: GoogleFonts.poppins(fontSize: 14),
                decoration: _inputDecoration(
                  label: 'Date of Birth',
                  icon: Icons.cake_outlined,
                  hint: 'Jan 1, 1998',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.calendar_month_rounded,
                        color: AppColors.primary, size: 20),
                    onPressed: _pickDate,
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Emergency / Medical Notes
              TextFormField(
                controller: _notesController,
                maxLines: 2,
                style: GoogleFonts.poppins(fontSize: 14),
                decoration: _inputDecoration(
                  label: 'Emergency / Medical Notes (Optional)',
                  icon: Icons.health_and_safety_outlined,
                  hint: 'e.g. Asthmatic, allergic to penicillin',
                ),
              ),
              const SizedBox(height: 22),

              // Save Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Text(
                          'Save Profile Permanently',
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle:
          GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
      labelStyle:
          GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
      prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.background,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }
}

// ── Shared Profile Sub-Widgets ─────────────────────────────────────

class _StatItem {
  final String value, label;
  final IconData icon;
  const _StatItem(
      {required this.value, required this.label, required this.icon});
}

class _StatCard extends StatelessWidget {
  final _StatItem item;
  const _StatCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
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
      child: Column(
        children: [
          Icon(item.icon, color: AppColors.primary, size: 22),
          const SizedBox(height: 6),
          Text(item.value,
              style: GoogleFonts.poppins(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          Text(item.label,
              style: GoogleFonts.poppins(
                  fontSize: 10, color: AppColors.textSecondary),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final bool isLast;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: GoogleFonts.poppins(
                            fontSize: 10, color: AppColors.textSecondary)),
                    Text(value,
                        style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1, color: AppColors.background),
      ],
    );
  }
}

class _AccountAction extends StatelessWidget {
  final IconData icon;
  final Color iconColor, iconBg;
  final String label;
  final VoidCallback onTap;

  const _AccountAction({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ActivityLog {
  final IconData icon;
  final Color color, bg;
  final String title, subtitle, time;
  const _ActivityLog({
    required this.icon,
    required this.color,
    required this.bg,
    required this.title,
    required this.subtitle,
    required this.time,
  });
}

class _ActivityCard extends StatelessWidget {
  final _ActivityLog log;
  const _ActivityCard({required this.log});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: log.bg, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Icon(log.icon, color: log.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(log.title,
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                Text(log.subtitle,
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(log.time,
              style: GoogleFonts.poppins(
                  fontSize: 9, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
