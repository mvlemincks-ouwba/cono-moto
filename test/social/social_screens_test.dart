import 'package:cono_moto/core/format.dart';
import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/social/expenses.dart';
import 'package:cono_moto/features/social/social_home_screen.dart';
import 'package:cono_moto/features/social/social_models.dart';
import 'package:cono_moto/features/social/social_providers.dart';
import 'package:cono_moto/features/social/ui/group_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

Future<void> pumpApp(WidgetTester tester, Widget home, {List overrides = const []}) async {
  tester.view.physicalSize = const Size(1080, 7500); // 360 dp de large
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [...overrides],
    child: MaterialApp(theme: CmTheme.dark(), home: home),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  late SharedPreferences prefs;
  final now = DateTime.now().toUtc();

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  const me = UserProfile(uid: 'me', name: 'Marc', colorValue: 0xFFFF6B1A, bike: 'MT-09', code: 'K7PM2X');
  final group = Group(
    id: 'ABCD2345',
    name: 'Les Virolos',
    createdBy: 'me',
    members: const [
      GroupMember(uid: 'me', name: 'Marc', colorValue: 0xFFFF6B1A),
      GroupMember(uid: 'a', name: 'Julie', colorValue: 0xFFFACC15),
      GroupMember(uid: 'b', name: 'Seb', colorValue: 0xFF4EA8FF),
    ],
    rally: RallyPoint(
      groupId: 'ABCD2345',
      groupName: 'Les Virolos',
      location: const GeoPoint(45.1, 3.1),
      label: 'Parking du col',
      setBy: 'Julie',
      setAt: now.subtract(const Duration(hours: 1)),
    ),
    expenses: [
      Expense(id: 'e1', label: 'Plein à Saint-Flour', amountCents: 6000, paidBy: 'me', participants: const ['me', 'a', 'b'], createdAt: now),
      Expense(id: 'e2', label: 'Péage', amountCents: 1200, paidBy: 'a', participants: const ['a', 'b'], category: ExpenseCategory.peage, createdAt: now),
    ],
  );

  List socialOverrides() => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        socialAvailableProvider.overrideWithValue(true),
        authUserProvider.overrideWith((ref) => Stream.value(null)),
        myUidProvider.overrideWithValue('me'),
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        myPositionProvider.overrideWithValue(const GeoPoint(45, 3)),
        friendIdsProvider.overrideWith((ref) => Stream.value(['a', 'b', 'c'])),
        userProfileProvider.overrideWith((ref, uid) => Stream.value(switch (uid) {
              'a' => const UserProfile(uid: 'a', name: 'Julie', colorValue: 0xFFFACC15, bike: 'Street Triple'),
              'b' => const UserProfile(uid: 'b', name: 'Seb', colorValue: 0xFF4EA8FF),
              _ => const UserProfile(uid: 'c', name: 'Lolo', colorValue: 0xFFA78BFA),
            })),
        liveStateProvider.overrideWith((ref, uid) => Stream.value(switch (uid) {
              'a' => LiveState(uid: 'a', location: const GeoPoint(45.2, 3.1), updatedAt: now, riding: true, speedKmh: 87),
              'b' => LiveState(uid: 'b', location: const GeoPoint(45, 3.5), updatedAt: now.subtract(const Duration(hours: 2))),
              _ => null,
            })),
        myGroupIdsProvider.overrideWith((ref) => Stream.value(['ABCD2345'])),
        groupProvider.overrideWith((ref, gid) => Stream.value(group)),
        mySharesProvider.overrideWith((ref) => Stream.value([LiveShare(token: 't' * 32, expiresAt: now.add(const Duration(hours: 2)))])),
        userReportsProvider.overrideWith((ref, uid) => Stream.value(uid == 'me'
            ? [
                RoadReport(
                  id: 'r1',
                  type: ReportType.gravillons,
                  location: const GeoPoint(45.01, 3),
                  createdAt: now,
                  authorUid: 'me',
                  authorName: 'Marc',
                  comment: 'sortie de virage',
                  expiresAt: now.add(const Duration(days: 7)),
                ),
              ]
            : <RoadReport>[])),
        userSharedRidesProvider.overrideWith((ref, uid) => Stream.value(uid == 'a'
            ? [
                FriendRide(
                  id: 'ride1',
                  authorUid: 'a',
                  authorName: 'Julie',
                  authorColorValue: 0xFFFACC15,
                  name: 'Gorges du Tarn',
                  startedAt: now.subtract(const Duration(days: 1)),
                  sharedAt: now.subtract(const Duration(hours: 3)),
                  distanceM: 182000,
                  movingTimeS: 11000,
                  maxSpeedKmh: 128,
                  maxLeanDeg: 42,
                  previewPolyline: Geo.encodePolyline(const [GeoPoint(44.2, 3.1), GeoPoint(44.3, 3.3), GeoPoint(44.25, 3.5)]),
                ),
              ]
            : <FriendRide>[])),
      ];

  testWidgets('mode solo : carte explicative', (tester) async {
    await pumpApp(tester, const SocialHomeScreen(), overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    expect(find.text('MODE SOLO'), findsOneWidget);
    expect(find.text('Pour activer le mode potes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('déconnecté : accueil puis validation du formulaire', (tester) async {
    await pumpApp(tester, const SocialHomeScreen(), overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      socialAvailableProvider.overrideWithValue(true),
      authUserProvider.overrideWith((ref) => Stream.value(null)),
    ]);
    expect(find.text('Roule en meute'), findsOneWidget);
    await tester.tap(find.text('Créer mon compte'));
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue dans la bande'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Créer mon compte'));
    await tester.pump();
    expect(find.text('Entre une adresse e-mail valide.'), findsOneWidget);
    await tester.tap(find.text('Connexion'));
    await tester.pump();
    expect(find.text('Mot de passe oublié ?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connecté : tableau de bord complet', (tester) async {
    await pumpApp(tester, const SocialHomeScreen(), overrides: socialOverrides());
    expect(tester.takeException(), isNull);
    expect(find.text('Marc'), findsWidgets);
    expect(find.text('TON CODE AMI'), findsOneWidget);
    expect(find.text('K'), findsOneWidget, reason: 'code en cases');
    expect(find.textContaining('Mes potes · 3'), findsOneWidget);
    expect(find.text('Julie'), findsWidgets);
    expect(find.textContaining('En balade · 87 km/h'), findsOneWidget);
    expect(find.textContaining('Vu il y a 2 h'), findsOneWidget);
    expect(find.text('Pas encore roulé avec l\'app'), findsOneWidget);
    expect(find.text('Les Virolos'), findsOneWidget);
    expect(find.textContaining('Regroupement : Parking du col'), findsOneWidget);
    expect(find.textContaining('On te doit'), findsOneWidget);
    expect(find.text('Mes signalements'), findsOneWidget);
    expect(find.textContaining('Gravillons · sortie de virage'), findsOneWidget);
    expect(find.text('Dernières balades des potes'), findsOneWidget);
    expect(find.text('Gorges du Tarn'), findsOneWidget);
    expect(find.textContaining('Ta position est partagée par lien'), findsOneWidget);
  });

  testWidgets('groupe : équipe puis frais et ajout de dépense', (tester) async {
    await pumpApp(tester, const GroupScreen(groupId: 'ABCD2345'), overrides: socialOverrides());
    expect(tester.takeException(), isNull);
    expect(find.text('Code d\'invitation'), findsOneWidget);
    expect(find.text('Parking du col'), findsOneWidget);
    expect(find.text('Marc (toi)'), findsOneWidget);
    expect(find.textContaining('En balade'), findsWidgets);

    await tester.tap(find.textContaining('Frais'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Qui doit quoi'), findsOneWidget);
    // Marc : +60 -20 = +40 ; Julie : -20 +12 -6 = -14 ; Seb : -20 -6 = -26.
    expect(find.text('Seb te doit ${Fmt.euros(26)}'), findsOneWidget);
    expect(find.text('Julie te doit ${Fmt.euros(14)}'), findsOneWidget);
    expect(find.text('Plein à Saint-Flour'), findsOneWidget);

    await tester.tap(find.text('Dépense'));
    await tester.pumpAndSettle();
    expect(find.text('Nouvelle dépense'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Montant'), 'abc');
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pump();
    expect(find.text('Indique un montant valide (ex : 23,50).'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Montant'), '30');
    await tester.pump();
    expect(find.textContaining('Soit environ ${Fmt.euros(10)} chacun'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
