import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/app_colors.dart';
import '../models/fake_caller.dart';
import '../services/auth_service.dart';
import '../services/fake_call_settings_service.dart';
import 'fake_call_dialog.dart';

/// Runs the "After 10s" fake call. Lives outside any screen, so the call still rings if the
/// user closes the sheet or switches tabs while waiting (app must stay open, as before).
class FakeCallScheduler {
  FakeCallScheduler._internal();
  static final FakeCallScheduler instance = FakeCallScheduler._internal();

  static const Duration defaultDelay = Duration(seconds: 10);

  /// Seconds until the scheduled call rings; 0 when nothing is scheduled.
  final ValueNotifier<int> secondsLeft = ValueNotifier<int>(0);

  Timer? _ringTimer;
  Timer? _tickTimer;

  bool get isScheduled => _ringTimer != null;

  /// Rings [caller] on [navigator] after exactly [delay]. Replaces any pending call.
  void schedule(NavigatorState navigator, FakeCaller caller, {Duration delay = defaultDelay}) {
    cancel();
    final ringAt = DateTime.now().add(delay);
    secondsLeft.value = delay.inSeconds;
    _ringTimer = Timer(delay, () {
      _clear();
      if (navigator.mounted) FakeCallDialog.showOn(navigator, caller: caller);
    });
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final ms = ringAt.difference(DateTime.now()).inMilliseconds;
      secondsLeft.value = math.max(0, (ms / 1000).ceil());
    });
  }

  void cancel() => _clear();

  void _clear() {
    _ringTimer?.cancel();
    _ringTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    secondsLeft.value = 0;
  }
}

/// Bottom sheet to choose who is calling, then start the fake call now or in 10 seconds.
/// With [pickOnly], it only saves the default caller (Settings, Followed Mode).
class FakeCallCallerSheet extends StatefulWidget {
  final bool pickOnly;

  const FakeCallCallerSheet({super.key, this.pickOnly = false});

  /// Returns the caller that was saved, or null if the sheet was dismissed.
  static Future<FakeCaller?> show(BuildContext context, {bool pickOnly = false}) {
    return showModalBottomSheet<FakeCaller>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FakeCallCallerSheet(pickOnly: pickOnly),
    );
  }

  @override
  State<FakeCallCallerSheet> createState() => _FakeCallCallerSheetState();
}

class _FakeCallCallerSheetState extends State<FakeCallCallerSheet> {
  FakeCallerPreset _preset = FakeCallerPreset.ammu;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  String? _nameError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await FakeCallSettingsService.instance.loadCaller();
    final custom = await FakeCallSettingsService.instance.lastCustomCaller();
    if (!mounted) return;
    setState(() {
      _preset = saved.preset;
      _nameCtrl.text = custom.customName;
      _phoneCtrl.text = custom.customPhone;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  /// The selected caller, or null (with an error shown) if the custom name is not usable.
  FakeCaller? _validatedCaller() {
    final caller = FakeCaller(_preset, customName: _nameCtrl.text, customPhone: _phoneCtrl.text);
    String? error;
    if (!caller.isValid) {
      error = 'Enter the caller\'s name';
    } else {
      String? ownName;
      try {
        ownName = AuthService.instance.isAuthenticated ? AuthService.instance.displayName : null;
      } catch (_) {}
      if (caller.usesOwnName(ownName)) {
        error = 'That is your own name. Pick another, or the call looks fake.';
      }
    }
    setState(() => _nameError = error);
    return error == null ? caller : null;
  }

  Future<void> _submit({required Duration? delay}) async {
    final caller = _validatedCaller();
    if (caller == null) return;
    HapticFeedback.mediumImpact();
    await FakeCallSettingsService.instance.saveCaller(caller);
    if (!mounted) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop(caller);
    if (widget.pickOnly) return;

    if (delay == null) {
      FakeCallScheduler.instance.cancel();
      await FakeCallDialog.showOn(navigator, caller: caller);
      return;
    }
    FakeCallScheduler.instance.schedule(navigator, caller, delay: delay);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${caller.name} will call in ${delay.inSeconds} seconds. Act natural!',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.actionBlue,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Cancel',
          textColor: Colors.white,
          onPressed: FakeCallScheduler.instance.cancel,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.pickOnly ? 'Fake Call Caller' : 'Fake Call',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Who should be calling you? Your choice is remembered.',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in FakeCallerPreset.values) _presetChip(preset),
                    ],
                  ),
                  if (_preset == FakeCallerPreset.custom) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _nameCtrl,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 40,
                      decoration: InputDecoration(
                        labelText: 'Caller name',
                        hintText: 'e.g. Nanu, Rina Apu',
                        errorText: _nameError,
                        counterText: '',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onChanged: (_) {
                        if (_nameError != null) setState(() => _nameError = null);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      maxLength: 20,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s()]'))],
                      decoration: InputDecoration(
                        labelText: 'Phone number (optional)',
                        hintText: '+880 1XXX-XXXXXX',
                        counterText: '',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (widget.pickOnly)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton(
                        onPressed: () => _submit(delay: null),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.actionBlue,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Text('Save', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                      ),
                    )
                  else ...[
                    _pendingCallBanner(),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: FilledButton.icon(
                              onPressed: () => _submit(delay: null),
                              icon: const Icon(Icons.phone_in_talk_rounded, size: 18),
                              label: Text('Now', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.actionBlue,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: () => _submit(delay: FakeCallScheduler.defaultDelay),
                              icon: const Icon(Icons.timer_rounded, size: 18, color: AppColors.actionBlue),
                              label: Text(
                                'After 10s',
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.actionBlue,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: AppColors.actionBlue, width: 1.3),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pendingCallBanner() {
    return ValueListenableBuilder<int>(
      valueListenable: FakeCallScheduler.instance.secondsLeft,
      builder: (context, seconds, _) {
        if (seconds <= 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              const Icon(Icons.timer_rounded, size: 16, color: AppColors.actionBlue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'A fake call rings in ${seconds}s',
                  style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
                ),
              ),
              TextButton(
                onPressed: FakeCallScheduler.instance.cancel,
                child: Text('Cancel', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _presetChip(FakeCallerPreset preset) {
    final selected = preset == _preset;
    final letter = preset == FakeCallerPreset.custom ? '+' : preset.displayName[0];
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      avatar: CircleAvatar(
        backgroundColor: selected ? Colors.white : AppColors.actionBlue.withValues(alpha: 0.12),
        child: Text(
          letter,
          style: GoogleFonts.poppins(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.actionBlue,
          ),
        ),
      ),
      label: Text(preset.pickerLabel),
      labelStyle: GoogleFonts.poppins(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: selected ? Colors.white : AppColors.textPrimary,
      ),
      selectedColor: AppColors.actionBlue,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: (_) {
        HapticFeedback.selectionClick();
        setState(() {
          _preset = preset;
          _nameError = null;
        });
      },
    );
  }
}
