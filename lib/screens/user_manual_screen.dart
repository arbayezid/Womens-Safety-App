import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';
import '../core/app_text.dart';
import '../core/app_tokens.dart';

/// In-app user manual: explains every feature of Woman Guard in plain language.
///
/// Content is static and grouped into sections. Each section is a card that expands to show
/// topics; a topic is a heading, a list of points (numbered when [_Topic.numbered] is set) and an
/// optional tip. The search field filters sections and topics by text.
class UserManualScreen extends StatefulWidget {
  const UserManualScreen({super.key});

  @override
  State<UserManualScreen> createState() => _UserManualScreenState();
}

class _UserManualScreenState extends State<UserManualScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Sections with only the topics that match [_query]. A section whose title or summary matches
  /// keeps all of its topics.
  List<_ManualSection> get _visibleSections {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _sections;
    final result = <_ManualSection>[];
    for (final section in _sections) {
      if (section.title.toLowerCase().contains(q) || section.summary.toLowerCase().contains(q)) {
        result.add(section);
        continue;
      }
      final topics = section.topics.where((t) => t.matches(q)).toList();
      if (topics.isNotEmpty) result.add(section.withTopics(topics));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final sections = _visibleSections;
    final searching = _query.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('User manual',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!searching) ...[
            const _IntroCard(),
            const SizedBox(height: 16),
          ],
          _SearchField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          const SizedBox(height: 16),
          if (sections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                'Nothing matches "${_query.trim()}". Try a shorter word, such as SOS, PIN or ride.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            )
          else
            for (final section in sections)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SectionCard(
                  // A new key when searching so matching sections open with their results shown.
                  key: ValueKey('${section.title}-$searching'),
                  section: section,
                  initiallyExpanded: searching,
                ),
              ),
          const SizedBox(height: 8),
          Text(
            'In immediate danger, call 999 first if you can.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  WIDGETS
// ─────────────────────────────────────────────────────────────

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        boxShadow: [AppShadow.tinted(AppColors.primary)],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.menu_book_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How Woman Guard works',
                    style: AppText.sectionTitle.copyWith(color: Colors.white)),
                const SizedBox(height: 4),
                Text(
                  'Start with "Getting started", then read the parts you plan to use. '
                  'Tap a section to open it.',
                  style: AppText.body.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: const [AppShadow.card],
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search the manual',
            hintStyle: AppText.body.copyWith(color: AppColors.textSecondary),
            prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textSecondary),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                    onPressed: onClear,
                  ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final _ManualSection section;
  final bool initiallyExpanded;

  const _SectionCard({super.key, required this.section, required this.initiallyExpanded});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: const [AppShadow.card],
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Removes the default divider lines ExpansionTile draws when open.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          iconColor: AppColors.primary,
          collapsedIconColor: AppColors.textSecondary,
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: section.iconBg,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            alignment: Alignment.center,
            child: Icon(section.icon, color: section.iconColor, size: 20),
          ),
          title: Text(section.title,
              style: AppText.cardTitle.copyWith(color: AppColors.textPrimary)),
          subtitle: Text(section.summary,
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < section.topics.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              _TopicView(topic: section.topics[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopicView extends StatelessWidget {
  final _Topic topic;

  const _TopicView({required this.topic});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(topic.heading, style: AppText.label.copyWith(color: AppColors.primary, fontSize: 13)),
        const SizedBox(height: 6),
        for (int i = 0; i < topic.points.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: topic.numbered
                      ? Text('${i + 1}.',
                          style: AppText.body.copyWith(
                              color: AppColors.textSecondary, fontWeight: FontWeight.w600))
                      : const Padding(
                          padding: EdgeInsets.only(top: 7, left: 4),
                          child: SizedBox(
                            width: 5,
                            height: 5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.textSecondary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                ),
                Expanded(
                  child: Text(topic.points[i],
                      style: AppText.body.copyWith(color: AppColors.textPrimary, height: 1.45)),
                ),
              ],
            ),
          ),
        if (topic.tip != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline_rounded, color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(topic.tip!,
                      style: AppText.body.copyWith(color: AppColors.textPrimary, height: 1.4)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  CONTENT
// ─────────────────────────────────────────────────────────────

class _ManualSection {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String summary;
  final List<_Topic> topics;

  const _ManualSection({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.summary,
    required this.topics,
  });

  _ManualSection withTopics(List<_Topic> filtered) => _ManualSection(
        icon: icon,
        iconColor: iconColor,
        iconBg: iconBg,
        title: title,
        summary: summary,
        topics: filtered,
      );
}

class _Topic {
  final String heading;
  final List<String> points;
  final bool numbered;
  final String? tip;

  const _Topic(this.heading, this.points, {this.numbered = false, this.tip});

  bool matches(String q) =>
      heading.toLowerCase().contains(q) ||
      points.any((p) => p.toLowerCase().contains(q)) ||
      (tip?.toLowerCase().contains(q) ?? false);
}

const List<_ManualSection> _sections = [
  // ── Getting started ──
  _ManualSection(
    icon: Icons.flag_rounded,
    iconColor: AppColors.primary,
    iconBg: AppColors.primarySurface,
    title: 'Getting started',
    summary: 'Sign in and set up the app in five steps',
    topics: [
      _Topic(
        'Sign in or explore as a guest',
        [
          'On the first screen, tap "Continue with Google" to create your account, or "Explore as Guest" to look around first.',
          'Guests can browse the app, but sending an SOS, adding contacts, Safe Journey, Ride Check-in and Being Followed all need you to sign in. The app asks you to sign in when you try them.',
          'You can sign in later from Settings with "Sign In with Google".',
        ],
      ),
      _Topic(
        'Set up the app before you need it',
        [
          'Allow the permissions the app asks for: location, notifications, SMS, Bluetooth and nearby devices. Without them, alerts cannot carry your location or reach your contacts.',
          'Verify your mobile number when asked. Guardians use it to link with you.',
          'Open the Contacts tab and add at least one emergency contact. Mark the most important one as primary with the star.',
          'Go to Settings > Security PIN and set a 4-digit PIN. Add a Duress PIN as well if you want the silent panic feature.',
          'Go to Settings > Background alerts and fix every item that is not ticked, so timers and alerts still work when the app is closed.',
        ],
        numbered: true,
        tip: 'Ask a friend to test with you once: send an SOS, let them tap "I\'m responding", then mark yourself safe.',
      ),
      _Topic(
        'Finding your way around',
        [
          'Safety: the home screen with the SOS button, your location and the quick actions.',
          'Map: safe places near you, community reports and the route to the nearest police station.',
          'Contacts: your emergency contacts, guardian requests and the people you protect. A red number shows new requests.',
          'Settings: safety features, PIN, fake call, device setup, history and help.',
          'Tap your picture at the top of the home screen to open your profile. The bell opens your notification inbox.',
        ],
      ),
    ],
  ),

  // ── SOS ──
  _ManualSection(
    icon: Icons.sos_rounded,
    iconColor: AppColors.sosRed,
    iconBg: AppColors.tintRed,
    title: 'Emergency SOS',
    summary: 'Alert your guardians with your live location',
    topics: [
      _Topic(
        'Sending an SOS',
        [
          'Tap the large red SOS button on the home screen.',
          'Your guardians who use Woman Guard get an alert on their phone with your live location.',
          'Every emergency contact with a phone number gets an SMS with a Google Maps link to where you are. Your primary contact is texted first.',
          'Live location tracking starts and the alert status appears at the top of the home screen.',
        ],
        numbered: true,
        tip: 'If the SMS cannot be sent automatically, the app shows an "SMS App" button. Tap it and press Send in your messages app.',
      ),
      _Topic(
        'While the alert is live',
        [
          'Tapping SOS again does not send a second alert. It opens a sheet with three choices.',
          '"Re-send alert": rings your guardians and texts your contacts again for the same alert.',
          '"Open Incident Room": see the live map, timeline and who is responding.',
          '"Hold to confirm I\'m safe": press and hold the green button to end the alert. Your contacts are told you are safe. If PIN protection is on, you must also enter your PIN.',
        ],
      ),
      _Topic(
        'Smart escalation',
        [
          'If no guardian taps "I\'m responding" within 3 minutes, your backup contacts are alerted and your other contacts get an SMS update.',
          'Escalation stops as soon as any guardian responds or you mark yourself safe.',
          'Turn this off in Settings > Smart escalation if you do not want it.',
        ],
      ),
      _Topic(
        'Incident Room',
        [
          'Shows the live location of the person in danger, how long the alert has been active and the path they have moved along.',
          '"Who gets alerted" lists every guardian and whether they have responded.',
          'The timeline records each step: alert sent, SMS rounds, guardians responding, escalation stages and the alert ending.',
          'Nearby safe places such as police stations are listed with their distance.',
          'Both the sender and the guardians can open the Incident Room.',
        ],
      ),
    ],
  ),

  // ── Quick actions ──
  _ManualSection(
    icon: Icons.grid_view_rounded,
    iconColor: AppColors.actionBlue,
    iconBg: AppColors.tintBlue,
    title: 'Quick actions',
    summary: 'Fake call, siren, camouflage and silent panic',
    topics: [
      _Topic(
        'Fake Call',
        [
          'Use it to get out of an uncomfortable situation with a believable excuse.',
          'Tap Fake Call, choose who is calling (your choice is remembered), then pick "Now" or "After 10s".',
          'Your phone rings with a realistic incoming call screen. Answer it and a recorded voice talks to you.',
          'In Settings > Fake call you can change the default caller, choose a Bangla or English voice, or record your own voice for each caller.',
        ],
      ),
      _Topic(
        'Loud Siren',
        [
          'Tap Loud Siren to play a loud alarm that draws attention and can scare someone off.',
          'While it plays, the tile turns red and reads "Stop siren". Tap it again to stop.',
        ],
      ),
      _Topic(
        'Camouflage',
        [
          'Turns Woman Guard into a working calculator so no one can tell what the app is.',
          'You need a Security PIN first. If you have not set one, the app offers to take you to Settings.',
          'To leave the calculator, type your Security PIN and press "=".',
        ],
        tip: 'Try it from Settings > Preview camouflage calculator so you know how to get out before you need it.',
      ),
      _Topic(
        'Silent Panic',
        [
          'Opens a PIN screen that looks like a normal security check.',
          'If someone forces you to unlock the app, enter your Duress PIN instead of your real PIN.',
          'The app then sends a silent SOS with no siren and no visible alert, and switches to the calculator. Your guardians are told it is a silent emergency and not to call you.',
          'Entering your real PIN here does nothing, so it is safe to show this screen to anyone.',
          'The whole phone also goes silent: calls, SMS, WhatsApp, Messenger, imo and every other app stop ringing, so nothing gives you away. Your normal sound comes back when you leave the calculator with your real PIN.',
        ],
        tip: 'Allow this once in Settings > Silence phone on Duress PIN. Without that permission the phone only switches to vibrate.',
      ),
    ],
  ),

  // ── Safe Journey ──
  _ManualSection(
    icon: Icons.directions_walk_rounded,
    iconColor: AppColors.actionGreen,
    iconBg: AppColors.successBackground,
    title: 'Safe Journey',
    summary: 'Let guardians watch you travel to a place',
    topics: [
      _Topic(
        'Starting a journey',
        [
          'Tap Safe Journey on the home screen.',
          'Search for a place, area or landmark, or pick one of the safe zones. The app finds the road route and estimates the travel time.',
          'Leave "Send SMS to trusted contacts" on if you want your contacts texted when you start and when you arrive.',
          'Tap "Start Safe Journey". Your guardians can now follow your live location.',
        ],
        numbered: true,
      ),
      _Topic(
        'How the app watches over you',
        [
          'Every 30 seconds the app checks your position against your route.',
          'It asks if you are safe when you leave the route, stay in one spot for 10 minutes, lose GPS for over 5 minutes, or are late past your expected arrival time.',
          'When you arrive within about 100 metres of your destination, the journey ends by itself.',
          'When a guardian opens your journey, you see their name, for example "Rahim is watching your location".',
        ],
      ),
      _Topic(
        'The "Are you safe?" check',
        [
          'You have 60 seconds to answer. If you do not, an SOS is sent automatically.',
          '"I\'m safe" confirms you are fine. When you are past your arrival time, the button reads "I\'m safe, end journey" and also ends the journey.',
          '"+15m Extend" (or "+15m Still going" when you are already late) adds 15 minutes to your expected arrival.',
          '"Send SOS now" alerts your guardians straight away.',
          'The check works even when the app is closed or the phone is locked, as long as Background alerts are set up.',
        ],
      ),
      _Topic(
        'Ending a journey',
        [
          'Open the journey card on the home screen and end it. If PIN protection is on, you must enter your PIN, so no one else can stop it for you.',
        ],
      ),
    ],
  ),

  // ── Being followed ──
  _ManualSection(
    icon: Icons.radar_rounded,
    iconColor: AppColors.actionOrange,
    iconBg: AppColors.tintAmber,
    title: 'Being Followed',
    summary: 'Share your location and check in quietly',
    topics: [
      _Topic(
        'Turning it on',
        [
          'Tap Being Followed on the home screen. It starts after a 5-second countdown that you can cancel.',
          'Your guardians get an alert and your contacts get an SMS. Your live location is shared until you turn it off.',
          'The screen shows which guardians are watching, or that they were alerted and none has opened it yet.',
        ],
        numbered: true,
      ),
      _Topic(
        'Silent check-ins',
        [
          'Every 5 minutes the phone vibrates and asks if you are OK. There is no sound, so the person following you will not hear it.',
          'If you do not answer the check-in, an SOS is sent.',
          'Check-ins pause while an SOS is active.',
        ],
      ),
      _Topic(
        'Tools on the Followed screen',
        [
          'Directions to the nearest police station.',
          'Fake call: rings in 30 seconds so you have a reason to talk on the phone.',
          'Loud Siren to draw attention.',
          'SOS: alerts guardians with your location, texts your contacts and starts escalation.',
          '"I\'m safe" ends Followed Mode, stops sharing your location and tells your guardians you are safe. It needs your PIN. Entering the Duress PIN here sends a silent SOS instead.',
        ],
      ),
    ],
  ),

  // ── Ride check-in ──
  _ManualSection(
    icon: Icons.local_taxi_rounded,
    iconColor: AppColors.actionBlue,
    iconBg: AppColors.tintSky,
    title: 'Ride Check-in',
    summary: 'Record the vehicle before you get in',
    topics: [
      _Topic(
        'Recording a ride',
        [
          'Tap Ride Check-in on the home screen.',
          'Take a photo of the number plate, or upload one. Stand close and keep the plate straight and in focus.',
          'Drag to select the plate area. The app reads the number online and fills in the fields.',
          'Compare every letter and digit with the photo, fix anything wrong, then tick "Number matches the plate".',
          'Add the driver\'s name and phone, the ride app and the destination if you know them. These are optional.',
          'Set the expected ride duration and choose which guardians to tell.',
          'Tap "Tell guardians and start ride".',
        ],
        numbered: true,
        tip: 'If the plate cannot be read, type it in by hand: city, series letter, the 2-digit class and the 4-digit serial. "Enter in another format" helps with unusual plates.',
      ),
      _Topic(
        'During the ride',
        [
          'Guardians see the vehicle number, the plate photo and your live location.',
          'The ride screen shows the time elapsed against the expected time.',
          'Tap "Extend ride time (+15m)" if the trip is taking longer.',
          'Tap "Active Ride SOS" if anything goes wrong.',
          'Tap "Arrived Safely" when you reach your destination. Tracking stops and your guardians are told.',
        ],
      ),
      _Topic(
        'If you do not check in',
        [
          'Ten minutes after the expected duration, the app asks you to check in. If you do not answer, an SOS is sent with your ride details.',
          'Past rides, plates and routes are kept in Settings > Ride history.',
        ],
      ),
      _Topic(
        'Ride app screenshot',
        [
          'You can also share a screenshot from your ride-hailing app with guardians. This is off by default because it may show personal account details.',
        ],
      ),
    ],
  ),

  // ── Contacts ──
  _ManualSection(
    icon: Icons.group_rounded,
    iconColor: AppColors.actionPurple,
    iconBg: AppColors.tintViolet,
    title: 'Emergency contacts',
    summary: 'Choose who gets your alerts',
    topics: [
      _Topic(
        'Adding a contact',
        [
          'Open the Contacts tab and tap "Add Contact".',
          'Enter their name, relationship and email address. The email links them to you in the app.',
          'Add their mobile number too, so SOS texts can reach them even without internet.',
          'Tap "Save & Send Request". They must accept the request in their own Woman Guard app before they get in-app alerts.',
        ],
        numbered: true,
        tip: 'If the person does not use Woman Guard yet, SMS alerts to their number still work.',
      ),
      _Topic(
        'Primary and backup contacts',
        [
          'Tap the star on a contact to make them your primary contact. They get your SOS alert and text first. Only one contact can be primary.',
          'A backup contact is only alerted if no one responds within 3 minutes of an SOS.',
        ],
      ),
      _Topic(
        'Managing contacts',
        [
          'Use the search box to find a contact.',
          'Press and hold a contact card to set or remove them as primary, edit their details, cancel a pending request or remove them.',
          'Tap the call or message buttons to reach a contact straight away.',
        ],
      ),
      _Topic(
        'Guardian requests and people you protect',
        [
          '"Guardian requests" lists people who want you as their guardian. Accept to receive their SOS alerts, or decline.',
          '"People I Protect" lists everyone whose alerts you receive. Tap a card to add them as your own emergency contact too.',
          'Choose "Stop protecting" to stop receiving someone\'s alerts.',
        ],
      ),
    ],
  ),

  // ── Being a guardian ──
  _ManualSection(
    icon: Icons.shield_rounded,
    iconColor: AppColors.successForeground,
    iconBg: AppColors.tintGreen,
    title: 'Being a guardian',
    summary: 'What you see when someone needs you',
    topics: [
      _Topic(
        'When someone sends an SOS',
        [
          'A full-screen alert appears on your phone, even if it is locked or the app is closed.',
          'Tap "I\'m responding" to let them and other guardians know you are on it. This pauses their escalation.',
          'You can view their GPS location, open the Incident Room or call 999 from the alert.',
          '"Dismiss (Not Responding)" closes the alert without responding.',
        ],
      ),
      _Topic(
        'Silent alerts',
        [
          'If the alert says it is silent, they used their Duress PIN and someone may be with them.',
          'Do not call their phone. A call could warn the person with them. Follow their location and call 999 if needed.',
        ],
      ),
      _Topic(
        'Journeys, rides and check-ins',
        [
          'When someone you protect starts a Safe Journey, a ride or Being Followed mode, a card appears on your home screen.',
          'Tap "Track their live location now" to follow them. They will see that you are watching.',
          'You are told if they miss a safety check-in.',
        ],
      ),
      _Topic(
        'Notification inbox',
        [
          'Tap the bell on the home screen to see every SOS, journey, ride and guardian request from the people you protect.',
          'Opening the inbox clears the badge. New entries stay highlighted until you tap them.',
        ],
      ),
    ],
  ),

  // ── Map ──
  _ManualSection(
    icon: Icons.map_rounded,
    iconColor: AppColors.actionGreen,
    iconBg: AppColors.tintMint,
    title: 'Map and safe places',
    summary: 'Find help nearby and report concerns',
    topics: [
      _Topic(
        'Safe places',
        [
          'The Map tab shows your current location and nearby safe zones such as police checkpoints, sorted by distance.',
          'Tap a safe zone to see it on the map and get directions in Google Maps.',
          'Turn on Safe Route Mode to show the route to the nearest police station.',
          'Use the map style button to switch between the standard, Voyager and dark maps.',
        ],
      ),
      _Topic(
        'Community safety reports',
        [
          'Coloured areas show places other women have reported: high-risk, moderate caution or community hazard zones.',
          'Tap a report to read it and see how many people confirmed it. Tap "Confirm Concern" if you noticed the same thing.',
          'To add your own, tap "Report a safety concern", describe what you noticed and submit. You need to be signed in.',
        ],
      ),
    ],
  ),

  // ── Automatic protection ──
  _ManualSection(
    icon: Icons.sensors_rounded,
    iconColor: AppColors.orangeDeep,
    iconBg: AppColors.tintOrange,
    title: 'Automatic protection',
    // summary: 'Shake, fall and low battery alerts',
    summary: 'Shake to SOS and safety switches',
    topics: [
      _Topic(
        'Shake to SOS',
        [
          'Shake the phone hard 3 times to send an SOS without looking for the button.',
          'You get 5 seconds to cancel if it was an accident.',
          'Turn it on or off in Settings > Shake to SOS.',
        ],
      ),
      // Fall detection and low battery alert hidden for now.
      // _Topic(
      //   'Fall detection',
      //   [
      //     'If the phone senses a hard impact followed by no movement, it shows "Possible fall detected".',
      //     'You have 30 seconds to say you are fine. Otherwise an SOS is sent. If PIN protection is on, cancelling needs your PIN.',
      //     'Turn it on or off in Settings > Fall detection.',
      //   ],
      // ),
      // _Topic(
      //   'Low battery alert',
      //   [
      //     'When your battery drops to 10% or lower and is not charging, your contacts get a text with your last location.',
      //     'Turn it on or off in Settings > Low battery alert.',
      //   ],
      // ),
      _Topic(
        'Other safety switches',
        [
          'Siren on automatic SOS: plays the siren when a check-in timer runs out and an SOS is sent for you.',
          'Live location sharing: lets your emergency contacts see your location.',
          'SMS alerts: texts your contacts from your SIM. Turn it off to alert them in the app only; no text messages are sent.',
        ],
      ),
    ],
  ),

  // ── PIN and camouflage ──
  _ManualSection(
    icon: Icons.pin_rounded,
    iconColor: AppColors.primary,
    iconBg: AppColors.primarySurface,
    title: 'Security PIN and Duress PIN',
    summary: 'Stop others from cancelling your alerts',
    topics: [
      _Topic(
        'Security PIN',
        [
          'A 4-digit PIN you choose in Settings > Security PIN.',
          'With "PIN protection" on, the PIN is needed to mark yourself safe, stop a Safe Journey, end Being Followed mode or cancel a fall alarm. Someone who takes your phone cannot quietly cancel your alert.',
          'Turn on "Require PIN to open app" to ask for the PIN every time the app opens.',
          'The PIN is also how you leave the camouflage calculator: type it and press "=".',
        ],
      ),
      _Topic(
        'Duress PIN',
        [
          'A second, different PIN for when someone forces you to unlock or cancel.',
          'Entering it anywhere the app asks for your PIN looks like it worked, but it sends a silent SOS and switches to the calculator.',
          'No siren plays and nothing on screen shows that an alert was sent. The phone goes fully silent for calls and messages until you exit.',
          'To come back from the calculator, type your real Security PIN and press "=".',
        ],
        tip: 'Choose a Duress PIN you can remember under stress, and make sure it is different from your Security PIN.',
      ),
    ],
  ),

  // ── ESP32 ──
  _ManualSection(
    icon: Icons.bluetooth_rounded,
    iconColor: AppColors.blueDeep,
    iconBg: AppColors.tintBlueSoft,
    title: 'ESP32 safety device',
    summary: 'Send an SOS with a hardware button',
    topics: [
      _Topic(
        'Connecting the device',
        [
          'Switch on your ESP32 device and keep it close to the phone.',
          'Open Settings > Device setup. Turn on Bluetooth if the app asks.',
          'Wait for the scan, then tap your ESP32 device in the list.',
          'When it says "Connected and armed for SOS trigger", the device is ready.',
        ],
        numbered: true,
      ),
      _Topic(
        'Using the device',
        [
          'Press the button on the ESP32 device to send an SOS, the same as tapping the SOS button.',
          'It works with the app closed or the phone locked, and reconnects by itself when the device is back in range.',
          'The device setup row shows the connection status and battery level.',
        ],
        tip: 'If the device is not found, make sure it is powered on, within range and not connected to another app, then tap Rescan.',
      ),
    ],
  ),

  // ── History and profile ──
  _ManualSection(
    icon: Icons.history_rounded,
    iconColor: AppColors.actionPurple,
    iconBg: AppColors.tintLavender,
    title: 'History and profile',
    summary: 'Past alerts, rides and your safety details',
    topics: [
      _Topic(
        'History',
        [
          'Settings > SOS history: every alert you sent or received, with its status (Active, Resolved, False Alarm or Responded), what triggered it and who responded.',
          'Settings > Ride history: past rides with plates and routes.',
          'Settings > Alert history: a log of alerts, siren use and contact changes.',
          'SOS records are kept as evidence and cannot be cleared.',
        ],
      ),
      _Topic(
        'Your profile',
        [
          'Tap your picture on the home screen, or the card at the top of Settings.',
          'Tap Edit to add your phone number, city and medical or emergency notes. Responders see these during an SOS.',
          'The profile shows how complete your setup is and your recent activity. You can clear routine activity; SOS records stay.',
        ],
      ),
    ],
  ),

  // ── Settings and reliability ──
  _ManualSection(
    icon: Icons.settings_rounded,
    iconColor: AppColors.textPrimary,
    iconBg: AppColors.neutralTile,
    title: 'Settings and background alerts',
    summary: 'Keep alerts working when the app is closed',
    topics: [
      _Topic(
        'Background alerts',
        [
          'Open Settings > Background alerts. Each item shows whether it is set up correctly.',
          'Tap any item that is not ticked to fix it: notifications, alarms and reminders, battery optimisation, full-screen alerts and, on some phones, auto-start.',
          'Without these, safety timers and guardian alerts may not work when the app is closed or the phone is asleep.',
        ],
      ),
      _Topic(
        'Other settings',
        [
          'Push notifications: turn app alerts and messages on or off.',
          'Privacy and data: how your data is used.',
          'Log Out: signs you out and switches the app to Guest Mode.',
        ],
      ),
    ],
  ),

  // ── Troubleshooting ──
  _ManualSection(
    icon: Icons.help_outline_rounded,
    iconColor: AppColors.warningForeground,
    iconBg: AppColors.warningSurface,
    title: 'Troubleshooting',
    summary: 'Common problems and how to fix them',
    topics: [
      _Topic(
        'SOS says I have no contacts',
        [
          'Add at least one emergency contact in the Contacts tab. The alert offers a "Contacts" button that takes you there.',
        ],
      ),
      _Topic(
        'SMS was not sent automatically',
        [
          'Allow the SMS permission in your phone settings. Meanwhile, tap "SMS App" on the message and press Send.',
        ],
      ),
      _Topic(
        'A guardian does not get in-app alerts',
        [
          'They must be signed in to Woman Guard and must have accepted your request. Until then, they only get SMS alerts.',
        ],
      ),
      _Topic(
        'Timers or alerts do not work when the app is closed',
        [
          'Open Settings > Background alerts and fix every item that is not ticked.',
        ],
      ),
      _Topic(
        'Location is missing or wrong',
        [
          'Turn on location and allow precise location for Woman Guard. Outdoors, GPS is faster and more accurate.',
        ],
      ),
      _Topic(
        'I forgot how to leave the calculator',
        [
          'Type your Security PIN and press "=". Entering the Duress PIN keeps the calculator on.',
        ],
      ),
    ],
  ),
];
