/// Pure Dart Geohash helper for spatial indexing and proximity clustering.
///
/// Implements standard base32 geohashing without requiring third-party plugins
/// or paid geocoding APIs.
class GeohashHelper {
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  static final Map<String, int> _decodeMap = {
    for (int i = 0; i < _base32.length; i++) _base32[i]: i,
  };

  /// Encodes a [latitude] and [longitude] coordinate pair into a base32 geohash string
  /// of length [precision].
  static String encode(double latitude, double longitude, {int precision = 6}) {
    if (latitude < -90.0 || latitude > 90.0) {
      throw ArgumentError('Latitude must be between -90 and 90');
    }
    if (longitude < -180.0 || longitude > 180.0) {
      throw ArgumentError('Longitude must be between -180 and 180');
    }

    double minLat = -90.0, maxLat = 90.0;
    double minLon = -180.0, maxLon = 180.0;

    final StringBuffer result = StringBuffer();
    bool isEven = true;
    int bit = 0;
    int ch = 0;

    while (result.length < precision) {
      if (isEven) {
        final double mid = (minLon + maxLon) / 2.0;
        if (longitude > mid) {
          ch |= (1 << (4 - bit));
          minLon = mid;
        } else {
          maxLon = mid;
        }
      } else {
        final double mid = (minLat + maxLat) / 2.0;
        if (latitude > mid) {
          ch |= (1 << (4 - bit));
          minLat = mid;
        } else {
          maxLat = mid;
        }
      }

      isEven = !isEven;
      if (bit < 4) {
        bit++;
      } else {
        result.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }

    return result.toString();
  }

  /// Decodes a [geohash] string into its bounding box:
  /// `[minLat, minLon, maxLat, maxLon]`.
  static List<double> decodeBoundingBox(String geohash) {
    if (geohash.isEmpty) {
      throw ArgumentError('Geohash string cannot be empty');
    }

    double minLat = -90.0, maxLat = 90.0;
    double minLon = -180.0, maxLon = 180.0;
    bool isEven = true;

    for (int i = 0; i < geohash.length; i++) {
      final char = geohash[i].toLowerCase();
      final cd = _decodeMap[char];
      if (cd == null) {
        throw ArgumentError('Invalid character "$char" in geohash');
      }

      for (int mask = 16; mask > 0; mask >>= 1) {
        if (isEven) {
          final mid = (minLon + maxLon) / 2.0;
          if ((cd & mask) != 0) {
            minLon = mid;
          } else {
            maxLon = mid;
          }
        } else {
          final mid = (minLat + maxLat) / 2.0;
          if ((cd & mask) != 0) {
            minLat = mid;
          } else {
            maxLat = mid;
          }
        }
        isEven = !isEven;
      }
    }

    return [minLat, minLon, maxLat, maxLon];
  }

  /// Returns the center `[latitude, longitude]` of the given [geohash].
  static List<double> decodeCenter(String geohash) {
    final bbox = decodeBoundingBox(geohash);
    final lat = (bbox[0] + bbox[2]) / 2.0;
    final lon = (bbox[1] + bbox[3]) / 2.0;
    return [lat, lon];
  }

  /// Returns the list of 8 surrounding neighbor geohashes for the given [geohash],
  /// preserving the same precision.
  static List<String> getNeighbors(String geohash) {
    final bbox = decodeBoundingBox(geohash);
    final minLat = bbox[0];
    final minLon = bbox[1];
    final maxLat = bbox[2];
    final maxLon = bbox[3];

    final latHeight = maxLat - minLat;
    final lonWidth = maxLon - minLon;
    final centerLat = (minLat + maxLat) / 2.0;
    final centerLon = (minLon + maxLon) / 2.0;
    final precision = geohash.length;

    // Helper to wrap latitude and longitude
    double clampLat(double lat) => lat.clamp(-89.9999, 89.9999);
    double wrapLon(double lon) {
      if (lon > 180.0) return lon - 360.0;
      if (lon < -180.0) return lon + 360.0;
      return lon;
    }

    final offsets = [
      [latHeight, 0.0], // North
      [-latHeight, 0.0], // South
      [0.0, lonWidth], // East
      [0.0, -lonWidth], // West
      [latHeight, lonWidth], // North-East
      [latHeight, -lonWidth], // North-West
      [-latHeight, lonWidth], // South-East
      [-latHeight, -lonWidth], // South-West
    ];

    final Set<String> neighbors = {};
    for (final off in offsets) {
      final neighborLat = clampLat(centerLat + off[0]);
      final neighborLon = wrapLon(centerLon + off[1]);
      final neighborHash = encode(neighborLat, neighborLon, precision: precision);
      if (neighborHash != geohash) {
        neighbors.add(neighborHash);
      }
    }

    return neighbors.toList();
  }

  /// Returns the center geohash plus its 8 neighbor geohashes (total 9 cells)
  /// for comprehensive 3x3 spatial grid querying.
  static List<String> getSearchCluster(double latitude, double longitude, {int precision = 6}) {
    final centerHash = encode(latitude, longitude, precision: precision);
    final neighbors = getNeighbors(centerHash);
    return [centerHash, ...neighbors];
  }
}
