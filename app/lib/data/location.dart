import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

class LocationResult {
  final LatLng? pos;
  final String? problem; // zašto lokacija nije dostupna (prikazuje se korisniku)
  /// otvara podešavanja telefona u kojima korisnik to može da ispravi
  final Future<bool> Function()? fix;
  LocationResult(this.pos, [this.problem, this.fix]);
}

class Locator {
  static LatLng? last;

  static Future<LocationResult> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationResult(last, 'Lokacija (GPS) je isključena na telefonu.', Geolocator.openLocationSettings);
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever) {
      return LocationResult(last, 'Aplikacija nema dozvolu za lokaciju.', Geolocator.openAppSettings);
    }
    if (perm == LocationPermission.denied) return LocationResult(last, 'Aplikacija nema dozvolu za lokaciju.');
    final known = await Geolocator.getLastKnownPosition();
    if (known != null) last = LatLng(known.latitude, known.longitude);
    try {
      final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)));
      last = LatLng(p.latitude, p.longitude);
      return LocationResult(last);
    } catch (e) {
      return LocationResult(last, last == null ? 'Lokacija nije dobijena: $e' : null);
    }
  }

  static double km(LatLng a, double lat, double lon) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, lat, lon) / 1000;

  /// radnje u radijusu (0 = sve), sortirane po udaljenosti
  static List<(Store, double?)> nearby(List<Store> stores, LatLng? pos, double radiusKm) {
    final out = <(Store, double?)>[];
    for (final s in stores) {
      final d = pos == null ? null : km(pos, s.lat, s.lon);
      if (radiusKm > 0 && d != null && d > radiusKm) continue;
      out.add((s, d));
    }
    out.sort((a, b) => (a.$2 ?? 0).compareTo(b.$2 ?? 0));
    return out;
  }
}
