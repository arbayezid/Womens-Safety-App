import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';

/// Map screen — shows a placeholder map view, quick location info,
/// safe-route toggle, and a list of nearby safe zones.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  bool _safeRouteEnabled = true;
  late AnimationController _pingController;
  late Animation<double> _pingAnimation;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    _pingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _pingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pingController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────
            _buildHeader(),

            // ── Map placeholder ───────────────────────────────────────
            _buildMapPlaceholder(),

            // ── Bottom sheet panel ────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLocationInfoCard(),
                    const SizedBox(height: 16),
                    _buildSafeRouteToggle(),
                    const SizedBox(height: 20),
                    _buildSafeZonesSection(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          Text(
            'Live Map',
            style: GoogleFonts.poppins(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          // Refresh button
          _IconBtn(
            icon: Icons.my_location_rounded,
            color: AppColors.primary,
            onTap: () {},
          ),
          const SizedBox(width: 8),
          _IconBtn(
            icon: Icons.layers_rounded,
            color: AppColors.textSecondary,
            onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildMapPlaceholder() {
    return Container(
      height: 260,
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD6E4F0), Color(0xFFB8D4E8)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Grid lines to simulate a map
          CustomPaint(
            size: const Size(double.infinity, double.infinity),
            painter: _MapGridPainter(),
          ),

          // Pulsing location pin
          Center(
            child: AnimatedBuilder(
              animation: _pingAnimation,
              builder: (_, child) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Ping ring
                    Opacity(
                      opacity: (1 - _pingAnimation.value).clamp(0.0, 1.0),
                      child: Container(
                        width: 80 * _pingAnimation.value,
                        height: 80 * _pingAnimation.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    // Accuracy circle
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary.withValues(alpha: 0.15),
                        border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.4),
                            width: 1),
                      ),
                    ),
                    // Location dot
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Safe zone markers
          _MapSafeZonePin(left: 60, top: 50, label: 'Hospital'),
          _MapSafeZonePin(right: 50, top: 80, label: 'Police'),
          _MapSafeZonePin(left: 80, bottom: 60, label: 'Metro'),

          // Map label overlay
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.map_rounded,
                      size: 13, color: AppColors.primary),
                  const SizedBox(width: 4),
                  Text(
                    'Banani, Dhaka',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.location_on_rounded,
                color: AppColors.primary, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current Location',
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                Text('Road 11, Banani, Dhaka',
                    style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.successBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Safe Zone',
                    style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.successForeground)),
              ),
              const SizedBox(height: 4),
              Text('23°42\'N  90°24\'E',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSafeRouteToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _safeRouteEnabled
              ? [AppColors.primary, AppColors.primaryLight]
              : [const Color(0xFFEEEEF2), const Color(0xFFE5E5EA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: _safeRouteEnabled
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                )
              ]
            : [],
      ),
      child: Row(
        children: [
          Icon(Icons.route_rounded,
              color: _safeRouteEnabled
                  ? Colors.white
                  : AppColors.textSecondary,
              size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Safe Route Mode',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _safeRouteEnabled
                        ? Colors.white
                        : AppColors.textPrimary,
                  ),
                ),
                Text(
                  _safeRouteEnabled
                      ? 'Avoiding high-risk areas'
                      : 'Tap to activate',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: _safeRouteEnabled
                        ? Colors.white.withValues(alpha: 0.8)
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _safeRouteEnabled,
            onChanged: (v) => setState(() => _safeRouteEnabled = v),
            activeThumbColor: Colors.white,
            activeTrackColor: Colors.white.withValues(alpha: 0.4),
            inactiveThumbColor: AppColors.textSecondary,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
          ),
        ],
      ),
    );
  }

  Widget _buildSafeZonesSection() {
    const zones = [
      _SafeZoneItem(
        icon: Icons.local_hospital_rounded,
        name: 'Dhaka Medical College',
        type: 'Hospital',
        distance: '0.4 km',
        iconColor: AppColors.sosRed,
        bgColor: Color(0xFFFFE5E5),
      ),
      _SafeZoneItem(
        icon: Icons.local_police_rounded,
        name: 'Banani Police Station',
        type: 'Police',
        distance: '0.7 km',
        iconColor: AppColors.actionBlue,
        bgColor: Color(0xFFDDEEFD),
      ),
      _SafeZoneItem(
        icon: Icons.train_rounded,
        name: 'Banani Metro Station',
        type: 'Metro',
        distance: '1.1 km',
        iconColor: AppColors.actionPurple,
        bgColor: Color(0xFFF0E6F9),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Nearby Safe Zones',
          style: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        ...zones.map((z) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SafeZoneCard(item: z),
            )),
      ],
    );
  }
}

// ─── Sub-widgets ────────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

class _MapSafeZonePin extends StatelessWidget {
  final double? left, right, top, bottom;
  final String label;
  const _MapSafeZonePin(
      {this.left, this.right, this.top, this.bottom, required this.label});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 6)
              ],
            ),
            child: Text(label,
                style: GoogleFonts.poppins(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(height: 2),
          const Icon(Icons.location_pin,
              color: AppColors.successForeground, size: 20),
        ],
      ),
    );
  }
}

class _SafeZoneItem {
  final IconData icon;
  final String name, type, distance;
  final Color iconColor, bgColor;
  const _SafeZoneItem({
    required this.icon,
    required this.name,
    required this.type,
    required this.distance,
    required this.iconColor,
    required this.bgColor,
  });
}

class _SafeZoneCard extends StatelessWidget {
  final _SafeZoneItem item;
  const _SafeZoneCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
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
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: item.bgColor,
                borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Icon(item.icon, color: item.iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                Text(item.type,
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(item.distance,
                  style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () {},
                child: Text('Navigate',
                    style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: AppColors.actionBlue,
                        decoration: TextDecoration.underline)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Custom painter to draw a grid simulating a map background.
class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFABC8DC).withValues(alpha: 0.4)
      ..strokeWidth = 1;
    const step = 32.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    // Draw a couple of simulated "roads"
    final roadPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, size.height * 0.55),
        Offset(size.width, size.height * 0.55), roadPaint);
    canvas.drawLine(Offset(size.width * 0.4, 0),
        Offset(size.width * 0.4, size.height), roadPaint);
  }

  @override
  bool shouldRepaint(_) => false;
}
