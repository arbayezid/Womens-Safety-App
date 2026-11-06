import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:smart_safety/services/route_service.dart';

void main() {
  group('RouteService.decodePolyline', () {
    test('decodes the reference Google polyline', () {
      final points = RouteService.decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(points.length, 3);
      expect(points[0].latitude, closeTo(38.5, 1e-5));
      expect(points[0].longitude, closeTo(-120.2, 1e-5));
      expect(points[1].latitude, closeTo(40.7, 1e-5));
      expect(points[1].longitude, closeTo(-120.95, 1e-5));
      expect(points[2].latitude, closeTo(43.252, 1e-5));
      expect(points[2].longitude, closeTo(-126.453, 1e-5));
    });

    test('empty string gives no points', () {
      expect(RouteService.decodePolyline(''), isEmpty);
    });
  });

  group('RouteService.parseOsrmResponse', () {
    const body = '{"code":"Ok","routes":[{"geometry":"_p~iF~ps|U_ulLnnqC",'
        '"duration":600.0,"distance":1500.0}]}';

    test('walking keeps the routed duration', () {
      final route = RouteService.parseOsrmResponse(body, JourneyTravelMode.walking)!;
      expect(route.distanceMeters, 1500.0);
      expect(route.durationSeconds, 600);
      expect(route.durationMinutes, 10);
      expect(route.points.length, 2);
    });

    test('vehicle duration includes the traffic allowance', () {
      final route = RouteService.parseOsrmResponse(body, JourneyTravelMode.vehicle)!;
      expect(route.durationSeconds, (600 * RouteService.vehicleTrafficFactor).round());
    });

    test('no route found returns null', () {
      expect(RouteService.parseOsrmResponse('{"code":"NoRoute","routes":[]}', JourneyTravelMode.walking), isNull);
      expect(RouteService.parseOsrmResponse('not json', JourneyTravelMode.walking), isNull);
    });

    test('route survives the Firestore round trip', () {
      final route = RouteService.parseOsrmResponse(body, JourneyTravelMode.vehicle)!;
      final back = JourneyRoute.fromMap(route.toMap())!;
      expect(back.polyline, route.polyline);
      expect(back.durationSeconds, route.durationSeconds);
      expect(back.mode, JourneyTravelMode.vehicle);
      expect(JourneyRoute.fromMap(null), isNull);
    });
  });

  group('Route geometry', () {
    // An L-shaped road in Dhaka: ~1 km north, then ~1 km east
    const start = LatLng(23.7800, 90.3500);
    const corner = LatLng(23.7890, 90.3500);
    const end = LatLng(23.7890, 90.3598);
    final route = [start, corner, end];

    test('a point on the road is ~0 m from the route', () {
      final d = RouteService.distanceToRouteMeters(23.7845, 90.3500, route);
      expect(d, lessThan(1.0));
    });

    test('a point 300 m off the road is ~300 m from the route', () {
      // 300 m east of the first leg's midpoint, far from the second leg
      final d = RouteService.distanceToRouteMeters(23.7820, 90.3500 + 300 / (111320 * 0.9151), route);
      expect(d, closeTo(300, 10));
    });

    test('remaining distance follows the road, not the straight line', () {
      final remaining = RouteService.remainingRouteMeters(start.latitude, start.longitude, route);
      final straight = const Distance().as(LengthUnit.Meter, start, end);
      expect(remaining, closeTo(2000, 30)); // ~1 km + ~1 km
      expect(remaining, greaterThan(straight + 500));
    });

    test('remaining distance shrinks as the traveler moves along the road', () {
      final atCorner = RouteService.remainingRouteMeters(corner.latitude, corner.longitude, route);
      expect(atCorner, closeTo(1000, 20));
      final atEnd = RouteService.remainingRouteMeters(end.latitude, end.longitude, route);
      expect(atEnd, lessThan(1.0));
    });
  });
}
