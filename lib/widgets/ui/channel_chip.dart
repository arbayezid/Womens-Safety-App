import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/app_text.dart';
import '../../core/app_tokens.dart';

/// How an emergency contact receives alerts.
enum AlertChannel {
  sms('SMS', Icons.sms_outlined, AppColors.actionGreen, AppColors.successBackground),
  app('App', Icons.notifications_none_rounded, AppColors.primary, AppColors.tintLavender),
  backup('Backup', Icons.shield_outlined, AppColors.actionOrange, AppColors.tintOrange),
  none('No alert channel', Icons.error_outline_rounded, AppColors.sosRed, AppColors.tintRed);

  const AlertChannel(this.label, this.icon, this.color, this.background);

  final String label;
  final IconData icon;
  final Color color;
  final Color background;
}

/// Small tinted chip with an icon naming one alert channel.
class ChannelChip extends StatelessWidget {
  const ChannelChip(this.channel, {super.key});

  final AlertChannel channel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: channel.background,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(channel.icon, size: 11, color: channel.color),
          const SizedBox(width: 3),
          Text(channel.label, style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: channel.color)),
        ],
      ),
    );
  }
}
