import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../models/safe_zone_model.dart';
import '../services/contact_service.dart';
import '../services/journey_service.dart';
import '../services/safe_zone_repository.dart';

/// Modal bottom sheet for configuring and starting a new Safe Journey session.
class StartJourneySheet extends StatefulWidget {
  const StartJourneySheet({super.key});

  @override
  State<StartJourneySheet> createState() => _StartJourneySheetState();
}

class _StartJourneySheetState extends State<StartJourneySheet> {
  SafeZone? _selectedSafeZone;
  final TextEditingController _customDestController = TextEditingController();
  int _estimatedMinutes = 20;
  bool _notifySms = true;
  bool _isStarting = false;
  List<ContactModel> _guardians = [];
  Position? _currentPosition;
  List<SafeZone> _suggestedZones = [];

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      _currentPosition = await Geolocator.getLastKnownPosition();
      final contacts = await ContactService.instance.getContacts();
      final repo = SafeZoneRepository.instance;
      await repo.loadSafeZones();
      if (!mounted) return;

      // Suggest the nearest safe zones when location is known
      final zones = _currentPosition != null
          ? repo.getNearestSafeZones(
              curLat: _currentPosition!.latitude,
              curLng: _currentPosition!.longitude,
              count: 5,
            )
          : repo.allSafeZones.take(5).toList();
      setState(() {
        _guardians = contacts;
        _suggestedZones = zones;
      });

      // Default to the first suggested safe zone if available
      if (zones.isNotEmpty) {
        _selectSafeZone(zones.first);
      }
    } catch (_) {}
  }

  void _selectSafeZone(SafeZone zone) {
    setState(() {
      _selectedSafeZone = zone;
      _customDestController.text = zone.name;
      if (_currentPosition != null) {
        final dist = JourneyService.haversineDistance(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          zone.latitude,
          zone.longitude,
        );
        _estimatedMinutes = JourneyService.estimateWalkingDurationMinutes(dist);
      } else {
        _estimatedMinutes = 25;
      }
    });
  }

  Future<void> _handleStartJourney() async {
    final destLabel = _customDestController.text.trim();
    if (destLabel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select or enter a destination.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isStarting = true);

    try {
      final destLat = _selectedSafeZone?.latitude ??
          (_currentPosition != null ? _currentPosition!.latitude + 0.015 : 23.8150);
      final destLng = _selectedSafeZone?.longitude ??
          (_currentPosition != null ? _currentPosition!.longitude + 0.015 : 90.4200);

      final guardianUids = _guardians
          .where((g) => g.contactUid != null && g.contactUid!.isNotEmpty)
          .map((g) => g.contactUid!)
          .toList();
      final guardianEmails = _guardians
          .where((g) => g.email.isNotEmpty)
          .map((g) => g.email.toLowerCase().trim())
          .toList();

      final destinationMap = {
        'latitude': destLat,
        'longitude': destLng,
        'label': destLabel,
        'address': _selectedSafeZone?.address ?? destLabel,
      };

      await JourneyService.instance.startJourney(
        destination: destinationMap,
        customEstimatedMinutes: _estimatedMinutes,
        notifySms: _notifySms,
        guardianUids: guardianUids,
        guardianEmails: guardianEmails,
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.directions_walk_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '🚶 Safe Journey active! Monitoring route & Dead-Man\'s switch.',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.actionGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start journey: $e', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  @override
  void dispose() {
    _customDestController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDFF5E3),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.shield_rounded, color: AppColors.actionGreen, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Start Safe Journey',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Live route tracking with Dead-Man\'s Switch',
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
            const SizedBox(height: 20),

            // Quick Safe Zones Chips
            Text(
              'Select Destination or Safe Zone',
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),

            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _suggestedZones.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final zone = _suggestedZones[i];
                  final isSelected = _selectedSafeZone?.id == zone.id;
                  return ChoiceChip(
                    label: Text(zone.name, style: GoogleFonts.poppins(fontSize: 12, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                    selected: isSelected,
                    onSelected: (_) => _selectSafeZone(zone),
                    selectedColor: AppColors.primarySurface,
                    backgroundColor: AppColors.background,
                    labelStyle: TextStyle(
                      color: isSelected ? AppColors.primary : AppColors.textPrimary,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected ? AppColors.primary : Colors.black.withValues(alpha: 0.08),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Destination Input field
            TextField(
              controller: _customDestController,
              decoration: InputDecoration(
                labelText: 'Destination Name / Location',
                prefixIcon: const Icon(Icons.place_rounded, color: AppColors.primary),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              style: GoogleFonts.poppins(fontSize: 14),
            ),
            const SizedBox(height: 18),

            // Walking ETA Adjuster
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_rounded, color: AppColors.actionOrange, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Estimated Walking Time',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$_estimatedMinutes mins',
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: _estimatedMinutes > 5
                        ? () => setState(() => _estimatedMinutes -= 5)
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: () => setState(() => _estimatedMinutes += 5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // SMS Checkbox Tile
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Send SMS to trusted contacts',
                style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Alerts phone contacts on start and arrival',
                style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              ),
              value: _notifySms,
              activeTrackColor: AppColors.actionGreen,
              onChanged: (val) => setState(() => _notifySms = val),
            ),
            const SizedBox(height: 18),

            // Start Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isStarting ? null : _handleStartJourney,
                icon: _isStarting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.directions_walk_rounded, color: Colors.white, size: 22),
                label: Text(
                  _isStarting ? 'Starting Journey...' : 'START SAFE JOURNEY',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.actionGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
