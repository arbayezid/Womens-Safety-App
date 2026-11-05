import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../constants/bd_plate_constants.dart';
import '../core/app_colors.dart';
import '../models/contact_model.dart';
import '../services/contact_service.dart';
import '../services/gemini_plate_reader.dart';
import '../services/plate_consensus.dart';
import '../services/ride_checkin_service.dart';
import '../services/ride_ocr_service.dart';
import 'active_ride_screen.dart';
import 'contacts_screen.dart';
import 'plate_crop_screen.dart';

/// Screen guiding the user through recording ride details, vehicle plate capture/OCR,
/// driver info, expected ETA, and notifying trusted guardians.
class RideCheckinScreen extends StatefulWidget {
  const RideCheckinScreen({super.key});

  @override
  State<RideCheckinScreen> createState() => _RideCheckinScreenState();
}

class _RideCheckinScreenState extends State<RideCheckinScreen> {
  final ImagePicker _picker = ImagePicker();

  // Step 1: Ride Type & App
  String _selectedRideType = BdPlateConstants.rideTypes.first; // 'CNG'
  String _selectedApp = 'No App';

  // Step 2: Photos & OCR
  File? _platePhoto;
  File? _screenshotPhoto;
  bool _shareScreenshot = false;
  bool _isOcrReading = false;
  String? _ocrFeedbackMessage;
  bool _ocrSuccess = false;

  /// Photo with orientation baked in, kept so the plate area can be re-selected
  PreparedPlatePhoto? _platePrepared;
  PreparedPlatePhoto? _screenshotPrepared;

  /// The plate area the user selected, shown next to the fields for comparison
  File? _plateCropPhoto;

  // OCR verification: the user must confirm an auto-read number before the ride starts
  bool _ocrFilledPlate = false;
  bool _plateConfirmed = false;
  bool _plateEditedAfterOcr = false;
  bool _checkCity = false;
  bool _checkSeries = false;
  bool _checkClass = false;
  bool _checkSerial = false;

  // Step 3: Vehicle details
  bool _isCustomPlateFormat = false;
  String _selectedCity = BdPlateConstants.metroCities.first;
  String _selectedSeries = BdPlateConstants.seriesList.first.english;
  final TextEditingController _classController = TextEditingController();
  final TextEditingController _serialController = TextEditingController();
  final TextEditingController _customPlateController = TextEditingController();

  final TextEditingController _driverNameController = TextEditingController();
  final TextEditingController _driverPhoneController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  int _expectedMinutes = 25;

  // Step 4: Guardians
  List<ContactModel> _allContacts = [];
  final Set<String> _selectedGuardianIds = {};
  bool _isLoadingContacts = true;
  bool _isStartingRide = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _classController.dispose();
    _serialController.dispose();
    _customPlateController.dispose();
    _driverNameController.dispose();
    _driverPhoneController.dispose();
    _destinationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final contacts = await ContactService.instance.getContacts();
      if (!mounted) return;
      setState(() {
        _allContacts = contacts;
        // Default: pre-select every regular (non-backup) contact. Before the single Primary
        // contact existed every contact was flagged primary, so this keeps the same selection.
        for (final c in contacts) {
          if (!c.isBackup) _selectedGuardianIds.add(c.id);
        }
        _isLoadingContacts = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingContacts = false);
    }
  }

  /// Builds live plate formatted string: e.g. "DHAKA METRO-THA 11-2233"
  String get _computedPlateFormatted {
    if (_isCustomPlateFormat) {
      final custom = _customPlateController.text.trim();
      return custom.isNotEmpty ? custom.toUpperCase() : 'ENTER VEHICLE PLATE';
    }

    final classNum = BdPlateConstants.normalizeDigits(_classController.text.trim());
    final serialNum = BdPlateConstants.normalizeDigits(_serialController.text.trim());

    final classDisplay = classNum.isNotEmpty ? classNum : '••';
    final serialDisplay = serialNum.isNotEmpty ? serialNum : '••••';

    return '$_selectedCity-$_selectedSeries $classDisplay-$serialDisplay';
  }

  /// The plate as printed on the vehicle, e.g. "ঢাকা মেট্রো-গ ৩১-৯৯৫৭"
  String get _banglaPlate {
    String bnDigits(String s) {
      final map = {
        for (final e in BdPlateConstants.bengaliToEnglishDigits.entries) e.value: e.key,
      };
      return s.split('').map((c) => map[c] ?? c).join();
    }

    var cityBn = _selectedCity == 'CHATTA METRO'
        ? 'চট্ট'
        : RideOcrService.banglaCityAliases.entries
                .where((e) => e.value == _selectedCity)
                .map((e) => e.key)
                .firstOrNull ??
            _selectedCity;
    if (_selectedCity.endsWith('METRO')) cityBn = '$cityBn মেট্রো';
    final seriesBn = BdPlateConstants.seriesList
            .where((s) => s.english == _selectedSeries)
            .map((s) => s.bengali)
            .firstOrNull ??
        _selectedSeries;

    final classNum = BdPlateConstants.normalizeDigits(_classController.text.trim());
    final serialNum = BdPlateConstants.normalizeDigits(_serialController.text.trim());
    final classDisplay = classNum.isNotEmpty ? bnDigits(classNum) : '••';
    final serialDisplay = serialNum.isNotEmpty ? bnDigits(serialNum) : '••••';
    return '$cityBn-$seriesBn $classDisplay-$serialDisplay';
  }

  Future<void> _choosePlateSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, color: AppColors.primary),
              title: Text('Take a photo of the plate', style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w600)),
              subtitle: Text('Stand close, plate straight and in focus', style: GoogleFonts.poppins(fontSize: 11)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: AppColors.actionBlue),
              title: Text('Upload a plate photo', style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source != null) await _pickPlatePhoto(source);
  }

  Future<void> _pickPlatePhoto(ImageSource source) async {
    try {
      // Full resolution matters: the plate is often a small part of the photo
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 3000,
        maxHeight: 3000,
        imageQuality: 95,
      );
      if (picked == null) return;

      final prepared = await _prepare(File(picked.path));
      if (prepared == null) return;
      _platePrepared = prepared;
      await _selectPlateArea(prepared, isScreenshot: false);
    } catch (e) {
      debugPrint('[RideCheckin] Plate photo error: $e');
      if (mounted) {
        setState(() => _isOcrReading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera access error. You can enter details manually below.', style: GoogleFonts.poppins()),
            backgroundColor: AppColors.actionOrange,
          ),
        );
      }
    }
  }

  Future<PreparedPlatePhoto?> _prepare(File file) async {
    setState(() {
      _isOcrReading = true;
      _ocrFeedbackMessage = 'Preparing photo…';
    });
    final prepared = await RideOcrService.instance.preparePhoto(file);
    if (!mounted) return null;
    setState(() => _isOcrReading = false);
    if (prepared == null) {
      setState(() {
        _ocrSuccess = false;
        _ocrFeedbackMessage = "Couldn't open this image. Please try another photo.";
      });
    }
    return prepared;
  }

  /// Opens the crop screen, then reads the selected area
  Future<void> _selectPlateArea(PreparedPlatePhoto prepared, {required bool isScreenshot}) async {
    final region = await Navigator.of(context).push<List<double>>(
      MaterialPageRoute(
        builder: (_) => PlateCropScreen(
          image: prepared.file,
          imageWidth: prepared.width,
          imageHeight: prepared.height,
          initialRegion: prepared.suggestedRegion,
        ),
      ),
    );
    if (region == null || !mounted) return;

    final isWhole = region[0] <= 0 && region[1] <= 0 && region[2] >= 1 && region[3] >= 1;
    final crop = isWhole ? null : await RideOcrService.instance.cropPlate(prepared.file, region);
    if (!mounted) return;

    setState(() {
      if (!isScreenshot) _platePhoto = prepared.file;
      _plateCropPhoto = crop;
    });
    await _runOcrPipeline(
      plateFile: isScreenshot ? null : (crop ?? prepared.file),
      screenshotFile: isScreenshot ? (crop ?? prepared.file) : null,
      isCrop: crop != null,
    );
  }

  Future<void> _reselectPlateArea() async {
    final screenshotMode = _platePrepared == null && _screenshotPhoto != null;
    var prepared = _platePrepared;
    if (prepared == null && _screenshotPhoto != null) {
      prepared = _screenshotPrepared ??= await _prepare(_screenshotPhoto!);
    }
    if (prepared == null || !mounted) return;
    await _selectPlateArea(prepared, isScreenshot: screenshotMode);
  }

  Future<void> _pickScreenshot() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (picked == null) return;

      final file = File(picked.path);
      setState(() {
        _screenshotPhoto = file;
        _screenshotPrepared = null;
      });

      await _runOcrPipeline(screenshotFile: file);
    } catch (e) {
      debugPrint('[RideCheckin] Gallery picker error: $e');
    }
  }

  Future<void> _runOcrPipeline({File? screenshotFile, File? plateFile, bool isCrop = false}) async {
    setState(() {
      _isOcrReading = true;
      _ocrFeedbackMessage = 'Reading vehicle number…';
      _ocrSuccess = false;
    });

    void progress(String message) {
      if (mounted) setState(() => _ocrFeedbackMessage = message);
    }

    try {
      RideOcrResult result = const RideOcrResult();

      // Prioritize screenshot OCR (Uber/Pathao plates are clearly printed in English Latin)
      if (screenshotFile != null) {
        result = await RideOcrService.instance.recognizePlate(
          screenshotFile,
          isPlateCrop: isCrop,
          onProgress: progress,
        );
      }

      // If screenshot had no plate or wasn't provided, try plate photo
      if (!result.hasPlate && plateFile != null) {
        result = await RideOcrService.instance.recognizePlate(
          plateFile,
          isPlateCrop: isCrop,
          onProgress: progress,
        );
      }

      if (!mounted) return;

      final readSomething =
          result.hasPlate || result.hasNumber || result.city != null || result.series != null;
      if (readSomething) {
        final uncertain = result.uncertainDigits;
        final via = result.source == 'cloud' ? 'AI' : 'on-device';
        setState(() {
          _ocrSuccess = result.hasPlate;
          _ocrFilledPlate = true;
          _plateConfirmed = false;
          _plateEditedAfterOcr = false;
          _isCustomPlateFormat = false;

          if (result.city != null && BdPlateConstants.metroCities.contains(result.city)) {
            _selectedCity = result.city!;
          }
          if (result.series != null &&
              BdPlateConstants.seriesList.any((s) => s.english == result.series)) {
            _selectedSeries = result.series!;
          }
          if (result.classNumber != null) _classController.text = result.classNumber!;
          if (result.serialNumber != null) _serialController.text = result.serialNumber!;

          _checkCity = result.city == null || result.cityConfidence < PlateVoting.confidentThreshold;
          _checkSeries = result.series == null || result.seriesConfidence < PlateVoting.confidentThreshold;
          _checkClass = result.classNumber == null || uncertain.any((i) => i < 2);
          _checkSerial = result.serialNumber == null || uncertain.any((i) => i >= 2);

          if (_seriesMismatchesRideType) {
            final bn = BdPlateConstants.seriesList
                .firstWhere((x) => x.english == _selectedSeries)
                .bengali;
            _ocrFeedbackMessage = 'Plate read ($via), but series $_selectedSeries ($bn) is unusual for a '
                '$_selectedRideType. Please check the series letter.';
          } else if (result.isConfident) {
            _ocrFeedbackMessage = 'Plate read ($via). Compare it with the photo and confirm below.';
          } else if (result.hasPlate) {
            _ocrFeedbackMessage = 'Plate read ($via), but some characters are uncertain. '
                'Please check the highlighted fields.';
          } else {
            _ocrFeedbackMessage = 'Plate partly read ($via). Please fill in or check the highlighted fields.';
          }

          if (result.driverName != null && _driverNameController.text.trim().isEmpty) {
            _driverNameController.text = result.driverName!;
          }
          if (result.driverPhone != null && _driverPhoneController.text.trim().isEmpty) {
            _driverPhoneController.text = result.driverPhone!;
          }
        });
      } else {
        setState(() {
          _ocrSuccess = false;
          _ocrFeedbackMessage = isCrop
              ? "Couldn't read the number. Try a closer, sharper photo, or enter it below."
              : "Couldn't read the number. Tap “Select plate area” or enter it below.";
        });
      }
    } catch (e) {
      debugPrint('[RideCheckin] OCR pipeline error: $e');
      if (mounted) {
        setState(() {
          _ocrSuccess = false;
          _ocrFeedbackMessage = "Couldn't read the number. Please enter it below.";
        });
      }
    } finally {
      if (mounted) setState(() => _isOcrReading = false);
    }
  }

  /// The read series is unusual for the chosen ride type (e.g. KHA on a CNG): likely a
  /// misread look-alike letter (থ/খ), so the field is flagged
  bool get _seriesMismatchesRideType {
    final expected = BdPlateConstants.expectedSeriesFor(_selectedRideType);
    return _ocrFilledPlate && expected != null && !expected.contains(_selectedSeries);
  }

  /// Called when the user changes any plate field after OCR filled it
  void _markPlateEdited() {
    if (_ocrFilledPlate) _plateEditedAfterOcr = true;
  }

  InputDecoration _plateFieldDecoration(String label, {String? hint, required bool needsCheck}) {
    final warn = needsCheck && _ocrFilledPlate;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: warn ? const Color(0xFFFFF4E5) : AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      helperText: warn ? 'Please check' : null,
      helperStyle: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.actionOrange, fontWeight: FontWeight.w600),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: warn ? const BorderSide(color: AppColors.actionOrange, width: 1.5) : BorderSide.none,
      ),
    );
  }

  Future<void> _handleStartRide() async {
    if (_allContacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No emergency contacts available. Please add contacts first.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
          action: SnackBarAction(
            label: 'Add Contacts',
            textColor: Colors.white,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ContactsScreen(isActive: true)),
              );
            },
          ),
        ),
      );
      return;
    }

    if (_selectedGuardianIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select at least one guardian to notify.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
        ),
      );
      return;
    }

    final formatted = _computedPlateFormatted;
    if (_isCustomPlateFormat && _customPlateController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter the vehicle plate number.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
        ),
      );
      return;
    }

    final classDigits = BdPlateConstants.normalizeDigits(_classController.text.trim());
    final serialDigits = BdPlateConstants.normalizeDigits(_serialController.text.trim());
    if (!_isCustomPlateFormat &&
        (!RegExp(r'^\d{2}$').hasMatch(classDigits) || !RegExp(r'^\d{4}$').hasMatch(serialDigits))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter the 2-digit class and 4-digit serial numbers.', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
        ),
      );
      return;
    }

    if (!_isCustomPlateFormat && _ocrFilledPlate && !_plateConfirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please compare the vehicle number with the photo and tick “Number matches the plate”.',
            style: GoogleFonts.poppins(),
          ),
          backgroundColor: AppColors.actionOrange,
        ),
      );
      return;
    }

    setState(() => _isStartingRide = true);

    try {
      final selectedContacts = _allContacts
          .where((c) => _selectedGuardianIds.contains(c.id))
          .toList();

      final guardianIds = selectedContacts
          .where((c) => c.contactUid != null && c.contactUid!.isNotEmpty)
          .map((c) => c.contactUid!)
          .toList();

      final guardianEmails = selectedContacts
          .where((c) => c.email.isNotEmpty)
          .map((c) => c.email.toLowerCase().trim())
          .toList();

      final guardianPhones = selectedContacts
          .where((c) => c.phone.trim().isNotEmpty)
          .map((c) => c.phone.trim())
          .toList();

      final destText = _destinationController.text.trim();
      final destinationMap = destText.isNotEmpty
          ? {
              'label': destText,
              'address': destText,
            }
          : null;

      final ride = await RideCheckinService.instance.startRideCheckin(
        rideType: _selectedRideType,
        appName: _selectedApp != 'No App' ? _selectedApp : null,
        plateFormatted: formatted,
        plateCity: !_isCustomPlateFormat ? _selectedCity : null,
        plateSeries: !_isCustomPlateFormat ? _selectedSeries : null,
        plateClass: !_isCustomPlateFormat ? BdPlateConstants.normalizeDigits(_classController.text.trim()) : null,
        plateSerial: !_isCustomPlateFormat ? BdPlateConstants.normalizeDigits(_serialController.text.trim()) : null,
        plateRawText: _isCustomPlateFormat ? _customPlateController.text.trim() : null,
        isPlateManual: !_ocrSuccess || _plateEditedAfterOcr,
        driverName: _driverNameController.text.trim().isNotEmpty ? _driverNameController.text.trim() : null,
        driverPhone: _driverPhoneController.text.trim().isNotEmpty ? _driverPhoneController.text.trim() : null,
        notes: _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
        platePhotoFile: _platePhoto,
        screenshotFile: _screenshotPhoto,
        shareScreenshot: _shareScreenshot,
        guardianIds: guardianIds,
        guardianEmails: guardianEmails,
        guardianPhones: guardianPhones,
        destination: destinationMap,
        expectedMinutes: _expectedMinutes,
      );

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ActiveRideScreen(rideId: ride.id),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start Ride Check-in: $e', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.sosRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _isStartingRide = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Ride Safety Check-in',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Intro header card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.local_taxi_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Track & Share Ride Details',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.primary,
                          ),
                        ),
                        Text(
                          'Vehicle number, live location & plate photo broadcast to trusted guardians.',
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── STEP 1: RIDE TYPE & APP ───────────────────────────────
            _buildSectionHeader('1. Choose Ride Type', Icons.commute_rounded),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: BdPlateConstants.rideTypes.map((type) {
                final isSelected = _selectedRideType == type;
                return ChoiceChip(
                  label: Text(type, style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                  selected: isSelected,
                  selectedColor: AppColors.primarySurface,
                  backgroundColor: AppColors.surface,
                  labelStyle: TextStyle(color: isSelected ? AppColors.primary : AppColors.textPrimary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isSelected ? AppColors.primary : Colors.black.withValues(alpha: 0.1)),
                  ),
                  onSelected: (val) {
                    if (val) {
                      setState(() {
                        _selectedRideType = type;
                        // Auto-adjust default series based on ride type, unless it was read
                        // from the plate
                        if (_ocrFilledPlate) {
                          // keep the series OCR / the user set
                        } else if (type == 'CNG') {
                          _selectedSeries = 'THA';
                        } else if (type.contains('Bike')) {
                          _selectedSeries = 'HA';
                        } else if (type.contains('Car')) {
                          _selectedSeries = 'GA';
                        }
                      });
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),

            Text('Ride Hailing App (Optional)', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: BdPlateConstants.appOptions.map((app) {
                final isSelected = _selectedApp == app;
                return ChoiceChip(
                  label: Text(app, style: GoogleFonts.poppins(fontSize: 11.5, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                  selected: isSelected,
                  selectedColor: const Color(0xFFDDEEFD),
                  backgroundColor: AppColors.surface,
                  labelStyle: TextStyle(color: isSelected ? AppColors.actionBlue : AppColors.textSecondary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isSelected ? AppColors.actionBlue : Colors.black.withValues(alpha: 0.08)),
                  ),
                  onSelected: (val) {
                    if (val) setState(() => _selectedApp = app);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            // ── STEP 2: PHOTO CAPTURE & OCR ────────────────────────────
            _buildSectionHeader('2. Capture Vehicle & Evidence', Icons.camera_alt_rounded),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isOcrReading ? null : _choosePlateSource,
                    icon: Icon(_platePhoto != null ? Icons.check_circle_rounded : Icons.photo_camera_rounded, size: 20),
                    label: Text(
                      _platePhoto != null ? 'New Plate Photo' : 'Plate Photo',
                      style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: _platePhoto != null ? AppColors.actionGreen : AppColors.primary),
                      foregroundColor: _platePhoto != null ? AppColors.actionGreen : AppColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isOcrReading ? null : _pickScreenshot,
                    icon: Icon(_screenshotPhoto != null ? Icons.image_rounded : Icons.add_photo_alternate_rounded, size: 20),
                    label: Text(
                      _screenshotPhoto != null ? 'Change Shot' : 'Add App Shot',
                      style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: _screenshotPhoto != null ? AppColors.actionBlue : Colors.grey.shade400),
                      foregroundColor: _screenshotPhoto != null ? AppColors.actionBlue : AppColors.textPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),

            if (_isOcrReading) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF9E6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFD56B)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.actionOrange),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _ocrFeedbackMessage ?? 'Reading vehicle number…',
                        style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.actionOrange),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_ocrFeedbackMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _ocrSuccess ? const Color(0xFFDFF5E3) : const Color(0xFFFEEDD8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _ocrSuccess ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                      size: 16,
                      color: _ocrSuccess ? AppColors.actionGreen : AppColors.actionOrange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _ocrFeedbackMessage!,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: _ocrSuccess ? AppColors.actionGreen : AppColors.actionOrange,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (!_isOcrReading && (_platePrepared != null || _screenshotPhoto != null))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _reselectPlateArea,
                  icon: const Icon(Icons.crop_rounded, size: 18),
                  label: Text(
                    'Select plate area',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                ),
              ),

            if (GeminiPlateReader.instance.isConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'When online, plate photos are read by Google Gemini AI for better accuracy.',
                  style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
                ),
              ),

            // Photo preview thumbnails row
            if (_platePhoto != null || _screenshotPhoto != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_platePhoto != null)
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(_platePhoto!, width: 72, height: 72, fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Plate', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  if (_platePhoto != null && _screenshotPhoto != null)
                    const SizedBox(width: 12),
                  if (_screenshotPhoto != null)
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(_screenshotPhoto!, width: 72, height: 72, fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('App', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],

            if (_screenshotPhoto != null) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _shareScreenshot,
                onChanged: (v) => setState(() => _shareScreenshot = v ?? false),
                title: Text(
                  'Also share ride app screenshot with guardians',
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  'Off by default (may contain personal account info)',
                  style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
            const SizedBox(height: 20),

            // ── STEP 3: VEHICLE DETAILS & LIVE PLATE PREVIEW ───────────
            _buildSectionHeader('3. Vehicle Details', Icons.directions_car_rounded),
            const SizedBox(height: 10),

            // The selected plate area, right above the read number, for comparison
            if (_plateCropPhoto != null && !_isCustomPlateFormat) ...[
              Text(
                'Your photo',
                style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                height: 96,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(_plateCropPhoto!, fit: BoxFit.contain),
              ),
              const SizedBox(height: 8),
            ],

            // LIVE PLATE BADGE PREVIEW
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.black, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    'BANGLADESH',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: AppColors.actionGreen,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Same text as printed on the vehicle, so it can be compared with the photo
                  if (!_isCustomPlateFormat)
                    Text(
                      _banglaPlate,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                        height: 1.3,
                      ),
                    ),
                  Text(
                    _computedPlateFormatted,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: _isCustomPlateFormat ? 18 : 14,
                      fontWeight: _isCustomPlateFormat ? FontWeight.w900 : FontWeight.w700,
                      color: _isCustomPlateFormat ? Colors.black87 : Colors.black54,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Toggle custom format
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _isCustomPlateFormat = !_isCustomPlateFormat),
                  child: Text(
                    _isCustomPlateFormat ? 'Switch to Standard BD Plate Format' : 'Enter in another format',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ],
            ),

            if (_isCustomPlateFormat) ...[
              TextField(
                controller: _customPlateController,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Vehicle Number / Plate Text',
                  hintText: 'e.g. DHAKA METRO-THA 11-2233',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
                style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700),
                onChanged: (_) => setState(() {}),
              ),
            ] else ...[
              // City & Series Selectors. The keys rebuild the dropdowns when OCR changes the
              // value: initialValue alone is only read once, so the old value stayed on screen.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // City Dropdown
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('city_$_selectedCity'),
                      initialValue: _selectedCity,
                      isExpanded: true,
                      decoration: _plateFieldDecoration('City / Metro', needsCheck: _checkCity),
                      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                      items: BdPlateConstants.metroCities.map((city) {
                        return DropdownMenuItem(value: city, child: Text(city, overflow: TextOverflow.ellipsis));
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() {
                          _selectedCity = val;
                          _checkCity = false;
                          _markPlateEdited();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Series Letter Dropdown (shows English + Bengali)
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('series_$_selectedSeries'),
                      initialValue: _selectedSeries,
                      isExpanded: true,
                      decoration: _plateFieldDecoration('Series', needsCheck: _checkSeries || _seriesMismatchesRideType),
                      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                      items: BdPlateConstants.seriesList.map((series) {
                        return DropdownMenuItem(
                          value: series.english,
                          child: Text(series.shortName, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() {
                          _selectedSeries = val;
                          _checkSeries = false;
                          _markPlateEdited();
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Class & Serial input fields
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _classController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [LengthLimitingTextInputFormatter(2)],
                      decoration: _plateFieldDecoration('Class (2 digits)', hint: '11', needsCheck: _checkClass),
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700),
                      onChanged: (_) => setState(() {
                        _checkClass = false;
                        _markPlateEdited();
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _serialController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [LengthLimitingTextInputFormatter(4)],
                      decoration: _plateFieldDecoration('Serial (4 digits)', hint: '2233', needsCheck: _checkSerial),
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700),
                      onChanged: (_) => setState(() {
                        _checkSerial = false;
                        _markPlateEdited();
                      }),
                    ),
                  ),
                ],
              ),

              // An auto-read number must be checked by the user before it is sent to guardians
              if (_ocrFilledPlate) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: _plateConfirmed ? const Color(0xFFDFF5E3) : const Color(0xFFFFF4E5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _plateConfirmed ? AppColors.actionGreen : AppColors.actionOrange,
                      width: 1.2,
                    ),
                  ),
                  child: CheckboxListTile(
                    value: _plateConfirmed,
                    activeColor: AppColors.actionGreen,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    onChanged: (v) => setState(() => _plateConfirmed = v ?? false),
                    title: Text(
                      'Number matches the plate',
                      style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'I compared every letter and digit with the photo. '
                      'নম্বরটি ছবির সাথে মিলিয়ে দেখেছি।',
                      style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),

            // Optional driver info & destination
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _driverNameController,
                    decoration: InputDecoration(
                      labelText: 'Driver Name (optional)',
                      prefixIcon: const Icon(Icons.person_outline_rounded, size: 20),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                    style: GoogleFonts.poppins(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _driverPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Driver Phone (optional)',
                      prefixIcon: const Icon(Icons.phone_outlined, size: 20),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                    style: GoogleFonts.poppins(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            TextField(
              controller: _destinationController,
              decoration: InputDecoration(
                labelText: 'Destination (optional)',
                prefixIcon: const Icon(Icons.place_outlined, size: 20, color: AppColors.primary),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
              style: GoogleFonts.poppins(fontSize: 13),
            ),
            const SizedBox(height: 14),

            // Expected duration adjuster
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
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
                        Text('Expected Ride Duration', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                        Text('$_expectedMinutes mins', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: _expectedMinutes > 10 ? () => setState(() => _expectedMinutes -= 5) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: () => setState(() => _expectedMinutes += 5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── STEP 4: CHOOSE GUARDIANS ──────────────────────────────
            _buildSectionHeader('4. Notify Guardians', Icons.group_rounded),
            const SizedBox(height: 10),

            if (_isLoadingContacts)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (_allContacts.isEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEEEE),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.sosRed.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('No emergency contacts added yet', style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.sosRed)),
                    const SizedBox(height: 4),
                    Text('To send ride check-in alerts and live location, please add contacts first.', style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary)),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ContactsScreen(isActive: true)),
                        ).then((_) => _loadContacts());
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                      child: Text('Add Contacts', style: GoogleFonts.poppins(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _allContacts.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: Colors.black.withValues(alpha: 0.06)),
                  itemBuilder: (context, i) {
                    final contact = _allContacts[i];
                    final isSelected = _selectedGuardianIds.contains(contact.id);
                    return CheckboxListTile(
                      value: isSelected,
                      activeColor: AppColors.primary,
                      title: Row(
                        children: [
                          Text(contact.name, style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w700)),
                          if (contact.isPrimary) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: AppColors.primarySurface, borderRadius: BorderRadius.circular(6)),
                              child: Text('PRIMARY', style: GoogleFonts.poppins(fontSize: 9.5, fontWeight: FontWeight.w800, color: AppColors.primary)),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        contact.phone.isNotEmpty ? contact.phone : contact.email,
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                      ),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedGuardianIds.add(contact.id);
                          } else {
                            _selectedGuardianIds.remove(contact.id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),

            const SizedBox(height: 28),

            // ── PRIMARY ACTION BUTTON ────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _isStartingRide ? null : _handleStartRide,
                icon: _isStartingRide
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.2),
                      )
                    : const Icon(Icons.navigation_rounded, color: Colors.white, size: 22),
                label: Text(
                  _isStartingRide ? 'NOTIFYING GUARDIANS...' : 'NOTIFY GUARDIANS & START RIDE',
                  style: GoogleFonts.poppins(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
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

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}
