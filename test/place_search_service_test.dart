import 'package:flutter_test/flutter_test.dart';
import 'package:smart_safety/services/place_search_service.dart';

void main() {
  group('PlaceSearchService.parsePhotonResponse', () {
    // Trimmed from a real Photon response for "Mirpur 1" near Dhaka
    const body = '''
{"features":[
 {"geometry":{"coordinates":[90.3509,23.7979],"type":"Point"},
  "properties":{"name":"Mirpur 1 Market","osm_key":"landuse","osm_value":"retail",
   "district":"Bishil","city":"Dhaka","county":"Dhaka Metropolitan"}},
 {"geometry":{"coordinates":[90.3535,23.7984],"type":"Point"},
  "properties":{"name":"Mirpur 1 Bus Stop","osm_key":"highway","osm_value":"bus_stop",
   "district":"Shah Ali Bagh","city":"Dhaka"}},
 {"geometry":{"coordinates":[90.3536,23.7985],"type":"Point"},
  "properties":{"name":"Mirpur 1 Bus Stop","osm_key":"highway","osm_value":"bus_stop",
   "district":"Shah Ali Bagh","city":"Dhaka"}},
 {"geometry":{"coordinates":[90.3523,23.8019],"type":"Point"},
  "properties":{"name":"Dhaka","osm_key":"place","osm_value":"city","city":"Dhaka"}},
 {"geometry":{"coordinates":[90.40,23.80],"type":"Point"},
  "properties":{"street":"Road 12","housenumber":"5","district":"Banani","city":"Dhaka"}},
 {"geometry":{"coordinates":[90.40,23.80],"type":"Point"},"properties":{"osm_key":"natural"}}
]}''';

    test('reads name, area line and coordinates', () {
      final results = PlaceSearchService.parsePhotonResponse(body);
      final first = results.first;
      expect(first.name, 'Mirpur 1 Market');
      expect(first.subtitle, 'Bishil, Dhaka, Dhaka Metropolitan');
      expect(first.latitude, closeTo(23.7979, 1e-6));
      expect(first.longitude, closeTo(90.3509, 1e-6));
      expect(first.category, 'landuse:retail');
      expect(first.isSafeZone, isFalse);
    });

    test('drops duplicate places and places without a name', () {
      final results = PlaceSearchService.parsePhotonResponse(body);
      expect(results.where((r) => r.name == 'Mirpur 1 Bus Stop').length, 1);
      expect(results.length, 4); // market, bus stop, Dhaka, Road 12
    });

    test('subtitle does not repeat the place name', () {
      final dhaka = PlaceSearchService.parsePhotonResponse(body).firstWhere((r) => r.name == 'Dhaka');
      expect(dhaka.subtitle, isEmpty);
    });

    test('an address without a name uses house number and street', () {
      final address = PlaceSearchService.parsePhotonResponse(body).firstWhere((r) => r.name.contains('Road 12'));
      expect(address.name, '5 Road 12');
      expect(address.subtitle, 'Banani, Dhaka');
    });

    test('bad input gives no suggestions', () {
      expect(PlaceSearchService.parsePhotonResponse('oops'), isEmpty);
      expect(PlaceSearchService.parsePhotonResponse('{"features":[]}'), isEmpty);
    });
  });
}
