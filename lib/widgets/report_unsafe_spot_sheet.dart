import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../models/safety_report_model.dart';
import '../services/location_service.dart';
import '../services/safety_report_service.dart';

/// Modal bottom sheet for submitting a new community safety report.
class ReportUnsafeSpotSheet extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const ReportUnsafeSpotSheet({
    super.key,
    this.initialLat,
    this.initialLng,
  });

  @override
  State<ReportUnsafeSpotSheet> createState() => _ReportUnsafeSpotSheetState();
}

class _ReportUnsafeSpotSheetState extends State<ReportUnsafeSpotSheet> {
  final TextEditingController _descController = TextEditingController();
  SafetyIncidentType _selectedType = SafetyIncidentType.poorLighting;

  double? _latitude;
  double? _longitude;
  String _locationAddress = 'Detecting current coordinates...';
  bool _isLocating = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    if (widget.initialLat != null && widget.initialLng != null) {
      setState(() {
        _latitude = widget.initialLat;
        _longitude = widget.initialLng;
        _locationAddress = 'Selected Map Location (${widget.initialLat!.toStringAsFixed(4)}, ${widget.initialLng!.toStringAsFixed(4)})';
        _isLocating = false;
      });
      return;
    }

    try {
      final loc = await LocationService.instance.getCurrentLocation(requestPermission: true);
      if (mounted) {
        if (loc.isSuccess && loc.data != null) {
          setState(() {
            _latitude = loc.data!.latitude;
            _longitude = loc.data!.longitude;
            _locationAddress = loc.data!.formattedAddress.isNotEmpty
                ? loc.data!.formattedAddress
                : '${loc.data!.latitude.toStringAsFixed(4)}, ${loc.data!.longitude.toStringAsFixed(4)}';
            _isLocating = false;
          });
        } else {
          setState(() {
            _latitude = 23.7935;
            _longitude = 90.4045; // Default Dhaka center fallback
            _locationAddress = 'Dhaka (Default center)';
            _isLocating = false;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _latitude = 23.7935;
          _longitude = 90.4045;
          _locationAddress = 'Dhaka (Approximate)';
          _isLocating = false;
        });
      }
    }
  }

  Future<void> _submitReport() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please provide a short description of the concern.',
            style: GoogleFonts.poppins(),
          ),
          backgroundColor: AppColors.sosRed,
        ),
      );
      return;
    }

    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to detect location. Please try again.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    HapticFeedback.mediumImpact();

    try {
      final res = await SafetyReportService.instance.submitReport(
        incidentType: _selectedType,
        description: desc,
        latitude: _latitude!,
        longitude: _longitude!,
      );

      if (!mounted) return;

      if (res.isSuccess) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '🛡️ Report added! Thank you for protecting the community.',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.safeGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res.errorMessage ?? 'Failed to submit report', style: GoogleFonts.poppins()),
            backgroundColor: res.isRateLimited ? Colors.orange.shade800 : AppColors.sosRed,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
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
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.actionOrange.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add_location_alt_rounded, color: AppColors.actionOrange, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Report Safety Concern',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Alert women in this area to stay vigilant',
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Current Location Pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.my_location_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _locationAddress,
                      style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_isLocating)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Incident Type Heading
            Text(
              'Select Issue Category',
              style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),

            // Incident Type Grid/Chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: SafetyIncidentType.values.map((type) {
                final isSelected = _selectedType == type;
                return ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        type.icon,
                        size: 16,
                        color: isSelected ? Colors.white : type.color,
                      ),
                      const SizedBox(width: 6),
                      Text(type.label),
                    ],
                  ),
                  selected: isSelected,
                  selectedColor: type.color,
                  backgroundColor: type.color.withValues(alpha: 0.12),
                  labelStyle: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? Colors.white : AppColors.textPrimary,
                  ),
                  onSelected: (val) {
                    if (val) setState(() => _selectedType = type);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            // Description TextField
            Text(
              'Details / Helpful Observations',
              style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descController,
              maxLines: 3,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: 'e.g. Streetlights off near the grocery store, secluded alleyway...',
                hintStyle: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade400),
                filled: true,
                fillColor: const Color(0xFFF9FAFB),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
              style: GoogleFonts.poppins(fontSize: 13),
            ),
            const SizedBox(height: 14),

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submitReport,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.shield_rounded, color: Colors.white, size: 20),
                label: Text(
                  _isSubmitting ? 'Submitting...' : 'Submit Report',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
