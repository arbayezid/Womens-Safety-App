import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Type scale. Styles carry size and weight only; colour comes from the
/// surrounding theme or from `copyWith(color: ...)` at the call site.
class AppText {
  AppText._();

  static TextStyle _poppins(double size, FontWeight weight, {double? letterSpacing}) =>
      GoogleFonts.poppins(fontSize: size, fontWeight: weight, letterSpacing: letterSpacing);

  /// "SOS" inside the emergency button.
  static final TextStyle sosNumeral = _poppins(42, FontWeight.w900, letterSpacing: 2);

  /// Screen titles.
  static final TextStyle pageTitle = _poppins(22, FontWeight.w700);

  /// Home greeting and large headings.
  static final TextStyle greeting = _poppins(18, FontWeight.w700);

  /// Section headings inside a screen.
  static final TextStyle sectionTitle = _poppins(16, FontWeight.w700);

  /// Card and row titles.
  static final TextStyle cardTitle = _poppins(14, FontWeight.w600);

  /// Body text, subtitles and descriptions.
  static final TextStyle body = _poppins(13, FontWeight.w400);

  /// Buttons inside cards and chips.
  static final TextStyle label = _poppins(12, FontWeight.w600);

  /// Meta lines and timestamps.
  static final TextStyle caption = _poppins(11, FontWeight.w500);

  /// Small section labels.
  static final TextStyle overline = _poppins(11, FontWeight.w600, letterSpacing: 0.6);
}
