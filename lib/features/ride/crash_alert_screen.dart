import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/location.dart';
import '../../core/native.dart';
import '../../core/theme.dart';
import '../../services/ride/crash_messages.dart';
import 'crash_alert_controller.dart';

/// Alerte de chute plein écran : compte à rebours, « JE VAIS BIEN » géant,
/// appel du 112, puis récapitulatif de ce qui a été envoyé.
///
/// Sur iPhone, Apple interdit l'envoi automatique de SMS : à l'expiration, les
/// potes sont alertés et l'écran Messages s'ouvre pré-rempli (gros bouton
/// « Envoyer le SMS » pour le rouvrir).
///
/// Poussé par le RideController via `rootNavigatorKey` ; l'état vit dans
/// [crashAlertProvider] (l'alerte part même si l'écran n'est pas affiché).
class CrashAlertScreen extends ConsumerStatefulWidget {
  const CrashAlertScreen({super.key});

  static Route<void> route() => PageRouteBuilder<void>(
    opaque: true,
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, _, _) => const CrashAlertScreen(),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
  );

  /// Lance une alerte d'essai (rien n'est envoyé) et l'affiche.
  static void startTest(BuildContext context, WidgetRef ref) {
    final pos = ref.read(positionHubProvider);
    ref.read(crashAlertProvider.notifier).trigger(at: pos?.point, accuracyM: pos?.accuracyM, test: true, seconds: 15);
    Navigator.of(context, rootNavigator: true).push(route());
  }

  @override
  ConsumerState<CrashAlertScreen> createState() => _CrashAlertScreenState();
}

class _CrashAlertScreenState extends ConsumerState<CrashAlertScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);
  bool _popped = false;
  bool _autoComposeDone = false;
  bool _composeOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _composeOnResume) {
      _composeOnResume = false;
      _composeSms();
    }
  }

  /// iPhone : ouvre Messages une fois, tout de suite si l'app est affichée,
  /// sinon dès que le motard (ou un témoin) revient dans l'app.
  void _maybeAutoCompose() {
    if (_autoComposeDone || !ref.read(crashAlertProvider).smsAwaitingUser) return;
    _autoComposeDone = true;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life == null || life == AppLifecycleState.resumed) {
      _composeSms();
    } else {
      _composeOnResume = true;
    }
  }

  Future<void> _composeSms() async {
    final alert = ref.read(crashAlertProvider);
    final r = await ref.read(crashAlertProvider.notifier).composeSms();
    if (!mounted) return;
    final msg = switch (r) {
      SmsComposeResult.unavailable =>
        'Ce téléphone ne peut pas envoyer de SMS : appelle ${alert.contactLabel} ou le 112.',
      SmsComposeResult.failed => 'L\'envoi du SMS a échoué : réessaie ou appelle ${alert.contactLabel}.',
      _ => null,
    };
    if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _callContact() async {
    HapticFeedback.heavyImpact();
    final alert = ref.read(crashAlertProvider);
    final ok = await NativeBridge.call(alert.contactPhone);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Appelle ${alert.contactPhone}.')));
    }
  }

  void _closeScreen() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  Future<void> _call112() async {
    HapticFeedback.heavyImpact();
    final ok = await launchUrl(Uri.parse('tel:112'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Compose le 112 depuis ton téléphone.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final alert = ref.watch(crashAlertProvider);
    ref.listen(crashAlertProvider.select((s) => s.phase), (prev, next) {
      if (next == CrashAlertPhase.idle) _closeScreen();
      if (next == CrashAlertPhase.sent) {
        _pulse.stop();
        _maybeAutoCompose();
      }
    });

    return PopScope(
      canPop: alert.phase == CrashAlertPhase.idle,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final t = alert.phase == CrashAlertPhase.countdown ? _pulse.value : 0.0;
            return Scaffold(
              backgroundColor: Color.lerp(const Color(0xFFB91C1C), const Color(0xFFDC2626), t),
              body: child,
            );
          },
          child: SafeArea(
            child: switch (alert.phase) {
              CrashAlertPhase.countdown => _Countdown(alert: alert, onCall: _call112),
              CrashAlertPhase.sending => const _Sending(),
              CrashAlertPhase.sent => _Sent(
                alert: alert,
                onCall: _call112,
                onComposeSms: _composeSms,
                onCallContact: _callContact,
              ),
              CrashAlertPhase.idle => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );
  }
}

class _Countdown extends ConsumerWidget {
  const _Countdown({required this.alert, required this.onCall});

  final CrashAlertState alert;
  final VoidCallback onCall;

  static const _red = Color(0xFFB91C1C);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(crashAlertProvider.notifier);
    final who = !alert.hasContact
        ? 'Tes potes seront prévenus'
        : alert.smsAutomatic
        ? '${alert.contactLabel} et tes potes seront prévenus'
        // iPhone : le SMS est préparé, pas envoyé tout seul.
        : 'Tes potes seront alertés et un SMS pour ${alert.contactLabel} sera prêt';

    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (alert.test) const _TestBanner(),
        const SizedBox(height: 8),
        const Icon(Icons.warning_rounded, color: Colors.white, size: 48),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'CHUTE DÉTECTÉE ?',
            style: CmTheme.numbers(size: 44, color: Colors.white, weight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$who dans',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ],
    );

    final ring = LayoutBuilder(
      builder: (context, c) {
        final d = math.max(0.0, math.min(math.min(c.maxWidth * 0.72, c.maxHeight - 16), 320.0));
        return Center(
          child: SizedBox.square(
            dimension: d,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: alert.secondsLeft / alert.totalSeconds),
                  duration: const Duration(milliseconds: 950),
                  builder: (_, v, _) => CircularProgressIndicator(
                    value: v,
                    strokeWidth: math.max(6, d * 0.06),
                    strokeCap: StrokeCap.round,
                    color: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(d * 0.18),
                  child: FittedBox(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${alert.secondsLeft}', style: CmTheme.numbers(size: 96, color: Colors.white)),
                        Text(
                          'secondes',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    // Bouton géant, utilisable avec des gants.
    final okButton = SizedBox(
      width: double.infinity,
      height: 120,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: _red,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          elevation: 6,
        ),
        onPressed: () {
          HapticFeedback.mediumImpact();
          ctrl.imOk();
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.thumb_up_alt_rounded, size: 34),
              const SizedBox(height: 4),
              Text(
                'JE VAIS BIEN',
                style: CmTheme.numbers(size: 40, color: _red, weight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );

    final secondary = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 60,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: onCall,
            icon: const Icon(Icons.phone_in_talk_rounded, size: 26),
            label: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Appeler les secours (112)', style: TextStyle(fontSize: 18)),
            ),
          ),
        ),
        TextButton(
          onPressed: ctrl.sendNow,
          style: TextButton.styleFrom(foregroundColor: Colors.white.withValues(alpha: 0.9)),
          child: const Text('J\'ai besoin d\'aide : prévenir maintenant', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth > c.maxHeight) {
          // Paysage : infos et compte à rebours à gauche, boutons à droite.
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      FittedBox(fit: BoxFit.scaleDown, child: header),
                      Expanded(child: ring),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(child: okButton),
                      const SizedBox(height: 10),
                      secondary,
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            children: [
              header,
              Expanded(child: ring),
              okButton,
              const SizedBox(height: 12),
              secondary,
            ],
          ),
        );
      },
    );
  }
}

class _TestBanner extends StatelessWidget {
  const _TestBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(999)),
      child: const Text(
        'MODE TEST · rien ne sera envoyé',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 0.8),
      ),
    );
  }
}

class _Sending extends StatelessWidget {
  const _Sending();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(dimension: 72, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 6)),
          const SizedBox(height: 24),
          Text('On prévient tes proches…', style: CmTheme.numbers(size: 32, color: Colors.white)),
        ],
      ),
    );
  }
}

class _Sent extends ConsumerWidget {
  const _Sent({required this.alert, required this.onCall, required this.onComposeSms, required this.onCallContact});

  final CrashAlertState alert;
  final VoidCallback onCall;
  final VoidCallback onComposeSms;
  final VoidCallback onCallContact;

  static const _red = Color(0xFFB91C1C);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(crashAlertProvider.notifier);
    final contact = alert.contactName.isNotEmpty ? '${alert.contactName} (${alert.contactPhone})' : alert.contactPhone;
    final at = alert.position;

    final rows = <Widget>[
      if (!alert.hasContact)
        const _ResultRow(
          ok: null,
          icon: Icons.sms_outlined,
          title: 'Pas de contact d\'urgence',
          subtitle: 'Ajoute-en un dans les réglages pour qu\'il reçoive un SMS.',
        )
      else if (alert.smsAutomatic)
        _ResultRow(
          ok: alert.smsSent,
          icon: Icons.sms_rounded,
          title: alert.smsSent == true
              ? (alert.test ? 'SMS qui serait envoyé à $contact' : 'SMS envoyé à $contact')
              : 'SMS non envoyé à $contact',
          subtitle: alert.smsSent == true ? null : 'Vérifie la permission SMS de Cono Moto.',
        )
      else
        // iPhone : Apple interdit l'envoi automatique, le SMS est préparé.
        _ResultRow(
          ok: alert.smsSent,
          icon: Icons.sms_rounded,
          title: alert.test
              ? 'SMS qui serait préparé pour $contact'
              : switch (alert.smsSent) {
                  true => 'SMS envoyé à $contact',
                  false => 'SMS non envoyé à $contact',
                  null => 'SMS prêt pour $contact',
                },
          subtitle: alert.test
              ? 'Sur iPhone, il faudra appuyer sur Envoyer : Apple interdit l\'envoi automatique.'
              : alert.smsSent == true
              ? null
              : 'Apple interdit l\'envoi automatique : appuie sur « Envoyer le SMS ».',
        ),
      _ResultRow(
        ok: alert.sosSent,
        icon: Icons.groups_rounded,
        title: switch (alert.sosSent) {
          true => alert.test ? 'Tes potes seraient alertés' : 'Tes potes sont alertés',
          false => 'Impossible d\'alerter tes potes',
          null => 'Potes non alertés',
        },
        subtitle: alert.sosSent == null ? 'Position GPS indisponible.' : null,
      ),
      _ResultRow(
        ok: at != null ? true : null,
        icon: Icons.place_rounded,
        title: at == null
            ? 'Position inconnue'
            : 'Position ${at.lat.toStringAsFixed(5)}, ${at.lng.toStringAsFixed(5)}'
                  '${alert.accuracyM != null ? ' (±${alert.accuracyM!.round()} m)' : ''}',
        subtitle: at == null ? null : mapsLink(at),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        if (alert.test) const Center(child: _TestBanner()),
        const SizedBox(height: 8),
        const Icon(Icons.sos_rounded, color: Colors.white, size: 56),
        const SizedBox(height: 4),
        Text(
          alert.test
              ? 'TEST TERMINÉ'
              : alert.smsAwaitingUser
              ? 'ALERTE CHUTE'
              : 'ALERTE ENVOYÉE',
          textAlign: TextAlign.center,
          style: CmTheme.numbers(size: 42, color: Colors.white, weight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          alert.test
              ? 'Voici ce qui partirait en cas de vraie chute.'
              : alert.smsAwaitingUser
              ? 'Appuie sur « Envoyer le SMS » pour prévenir ${alert.contactLabel}. Les secours : 112.'
              : 'Reste où tu es si tu es blessé. Les secours : 112.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        if (alert.smsAwaitingUser) ...[
          // iPhone : action principale, en haut et géante (utilisable avec des gants).
          SizedBox(
            height: 84,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: _red,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                elevation: 6,
              ),
              onPressed: () {
                HapticFeedback.mediumImpact();
                onComposeSms();
              },
              icon: const Icon(Icons.sms_rounded, size: 30),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Envoyer le SMS à ${alert.contactLabel}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(CmSpacing.radius),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: rows),
        ),
        if (alert.smsMessage != null && alert.hasContact) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(CmSpacing.radiusSm + 4),
            ),
            child: Text(
              '« ${alert.smsMessage} »',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 13.5, height: 1.35),
            ),
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: _red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: onCall,
            icon: const Icon(Icons.phone_in_talk_rounded),
            label: const Text('Appeler les secours (112)', style: TextStyle(fontSize: 18)),
          ),
        ),
        if (alert.hasContact && !alert.test) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 60,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white, width: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              onPressed: onCallContact,
              icon: const Icon(Icons.call_rounded),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Appeler ${alert.contactLabel}', style: const TextStyle(fontSize: 17)),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: () => ctrl.cancelAlert(),
            icon: Icon(alert.test ? Icons.check_rounded : Icons.cancel_outlined),
            label: Text(
              alert.test ? 'Terminer le test' : 'Annuler l\'alerte (tout va bien)',
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ),
        if (!alert.test) ...[
          const SizedBox(height: 6),
          Text(
            alert.smsSent != true
                ? 'Annuler lève l\'alerte chez tes potes.'
                : alert.smsAutomatic
                ? 'Annuler lève l\'alerte chez tes potes et envoie un SMS « fausse alerte » à ton contact.'
                : 'Annuler lève l\'alerte chez tes potes et prépare un SMS « fausse alerte » pour ton contact.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
          ),
          TextButton(
            onPressed: ctrl.dismissKeepingAlert,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Fermer (l\'alerte reste active)'),
          ),
        ],
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.ok, required this.icon, required this.title, this.subtitle});

  /// true = réussi, false = échec, null = non tenté.
  final bool? ok;
  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final badge = switch (ok) {
      true => const Icon(Icons.check_circle_rounded, color: Color(0xFF86EFAC)),
      false => const Icon(Icons.error_rounded, color: Color(0xFFFDE68A)),
      null => Icon(Icons.remove_circle_outline, color: Colors.white.withValues(alpha: 0.6)),
    };
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
      trailing: badge,
    );
  }
}
