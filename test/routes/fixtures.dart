import 'dart:convert';
import 'dart:io';

/// Lit un fichier de test/routes/fixtures.
String fixture(String name) => File('test/routes/fixtures/$name').readAsStringSync();

/// Lit et décode un fixture JSON.
dynamic fixtureJson(String name) => jsonDecode(fixture(name));
