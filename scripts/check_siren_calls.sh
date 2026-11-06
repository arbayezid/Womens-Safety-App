#!/usr/bin/env bash
# Guardrail: only these files may start the siren. An incoming alert rings only through
# NotificationService._ringIfUnclaimed (after claiming its ring key) or the native
# GuardianAlertService; home_screen.dart holds the sender's own siren button.
# Fails (exit 1) and lists the offending files when startSiren( appears anywhere else in lib/.
cd "$(dirname "$0")/.." || exit 1
grep -rln "startSiren(" lib | grep -vE "siren_service|notification_service|home_screen|emergency_service" && exit 1 || exit 0
