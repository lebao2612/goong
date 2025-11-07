import 'dart:async'; // Cần thiết cho StreamSubscription

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:http/http.dart' as http;

import 'package:flutter_polyline_points/flutter_polyline_points.dart';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'package:geolocator/geolocator.dart';

import 'dart:math' as math;

import 'package:flutter/services.dart';

void main() {
  runApp(const MaterialApp(home: GoongRoutingMap()));
}

class GoongRoutingMap extends StatefulWidget {
  const GoongRoutingMap({super.key});

  @override
  State<GoongRoutingMap> createState() => _GoongRoutingMapState();
}

class _GoongRoutingMapState extends State<GoongRoutingMap> {
  mapbox.MapboxMap? _mapboxMap;

  mapbox.PointAnnotationManager? _pointManager;

  mapbox.PolylineAnnotationManager? _polylineManager;

  List<mapbox.Position> _routeCoordinates = []; // Lưu các điểm của tuyến đường

  mapbox.PointAnnotation? _userLocationMarker; // Marker xe hơi

  mapbox.PolylineAnnotation? _routePolyline; // Lưu đường line

  Uint8List? _arrowIconData; // Dữ liệu ảnh icon

  bool _isIconLoaded = false;

  final TextEditingController _startCtrl = TextEditingController();

  final TextEditingController _endCtrl = TextEditingController();

  final String _goongMapKey = "d4wzBWgAIyb3EvELksUXwTLrIKGlZPd4KFGrATgj";

  final String _goongApiKey = "xdfsmGusMta5D9ICaSarzdmCWWOucKDKiWRbbbaq";

  // --- CÁC BIẾN MỚI CHO NAVIGATION ---

  /// Theo dõi stream vị trí

  StreamSubscription<Position>? _locationSubscription;

  /// Lưu tọa độ của ĐIỂM ĐẾN (Điểm B)

  mapbox.Position? _destinationCoords;

  /// Cờ (flag) để biết có đang trong chế độ điều hướng không

  bool _isNavigating = false;

  /// Ngưỡng (bằng mét) để coi là "đi lạc"

  static const double OFF_ROUTE_THRESHOLD = 50.0;

  // --- KẾT THÚC BIẾN MỚI ---

  @override
  void initState() {
    super.initState();

    mapbox.MapboxOptions.setAccessToken(
      "pk.eyJ1IjoiZHVjLWRheS1uZSIsImEiOiJjbWg0N3ZndGswZmNwMmpuNGN1cTJnYjlxIn0.m0RNPqi3Z6NYjy9_Mr1eEw",
    );

    _loadIcon();
  }

  /// Load icon từ asset

  Future<void> _loadIcon() async {
    try {
      final ByteData byteData = await rootBundle.load(
        'assets/navigation_arrow.png',
      );

      _arrowIconData = byteData.buffer.asUint8List();

      setState(() {
        _isIconLoaded = true;
      });
    } catch (e) {
      debugPrint("Lỗi load icon: $e");
    }
  }

  void _onMapCreated(mapbox.MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    _pointManager = await mapboxMap.annotations.createPointAnnotationManager();

    _polylineManager = await mapboxMap.annotations
        .createPolylineAnnotationManager();
  }

  /// 🗺️ Geocode địa chỉ -> toạ độ

  Future<Map<String, double>?> _geocode(String address) async {
    final url = Uri.parse(
      "https://rsapi.goong.io/Geocode?address=$address&api_key=$_goongApiKey",
    );

    final res = await http.get(url);

    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body);

    if (data["results"] == null || data["results"].isEmpty) return null;

    final loc = data["results"][0]["geometry"]["location"];

    return {"lat": loc["lat"], "lng": loc["lng"]};
  }

  /// 🔄 Reverse geocode (tọa độ -> địa chỉ)

  Future<String?> _reverseGeocode(double lat, double lng) async {
    final url = Uri.parse(
      "https://rsapi.goong.io/Geocode?latlng=$lat,$lng&api_key=$_goongApiKey",
    );

    final res = await http.get(url);

    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body);

    if (data["results"] == null || data["results"].isEmpty) return null;

    return data["results"][0]["formatted_address"];
  }

  /// 🚗 Vẽ tuyến đường từ A -> B (Dùng địa chỉ)

  Future<void> _drawRoute(String start, String end) async {
    if (_mapboxMap == null) return;

    // Dừng navigation cũ (nếu có)

    await _stopRealTimeTracking();

    final from = await _geocode(start);

    final to = await _geocode(end);

    if (from == null || to == null) {
      _showSnack("Không tìm thấy địa chỉ");

      return;
    }

    // --- THÊM DÒNG NÀY ---

    // Lưu lại tọa độ điểm đến để dùng cho việc re-route

    _destinationCoords = mapbox.Position(to["lng"]!, to["lat"]!);

    // --- KẾT THÚC THÊM ---

    final success = await _fetchAndDrawRoute(
      mapbox.Position(from["lng"]!, from["lat"]!),

      _destinationCoords!,
    );

    if (success) {
      // Focus camera

      await _mapboxMap?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(
              (from["lng"]! + to["lng"]!) / 2,

              (from["lat"]! + to["lat"]!) / 2,
            ),
          ),

          zoom: 12,
        ),

        mapbox.MapAnimationOptions(duration: 1000),
      );
    }
  }

  // --- HÀM MỚI ---

  /// 🚗 Lấy và vẽ tuyến đường từ TỌA ĐỘ (Dùng cho re-route)

  Future<bool> _fetchAndDrawRoute(
    mapbox.Position start,
    mapbox.Position end,
  ) async {
    final url = Uri.parse(
      "https://rsapi.goong.io/Direction?origin=${start.lat},${start.lng}&destination=${end.lat},${end.lng}&vehicle=car&api_key=$_goongApiKey",
    );

    final res = await http.get(url);

    if (res.statusCode != 200) {
      _showSnack("Không lấy được tuyến đường");

      return false;
    }

    final data = jsonDecode(res.body);

    if (data["routes"] == null || data["routes"].isEmpty) {
      _showSnack("Không tìm thấy tuyến đường");

      return false;
    }

    final encoded = data["routes"][0]["overview_polyline"]["points"];

    final routePoints = PolylinePoints.decodePolyline(encoded);

    final coords = routePoints
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();

    // Lưu lại tuyến đường mới

    _routeCoordinates = coords;

    // ===== IN TUYẾN ĐƯỜNG TỪ GOONG API =====

    print("--- [GOONG API] Đã nhận tuyến đường mới ---");

    print("Tổng số điểm: ${_routeCoordinates.length}");

    for (var pos in _routeCoordinates) {
      print(
        'Goong Lng: ${pos.lng.toDouble()}, Goong Lat: ${pos.lat.toDouble()}',
      );
    }

    print("--- [GOONG API] Kết thúc tuyến đường ---");

    // =============================================

    // Xoá cũ

    await _polylineManager?.deleteAll();

    await _pointManager?.deleteAll();

    _userLocationMarker = null;

    _routePolyline = null;

    // Vẽ line mới

    _routePolyline = await _polylineManager?.create(
      mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: coords),

        lineColor: Colors.blue.value,

        lineWidth: 5.0,
      ),
    );

    // Thêm marker Start - End

    await _pointManager?.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: start),

        textField: "Start",

        textSize: 14,
      ),
    );

    await _pointManager?.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: end),

        textField: "End",

        textSize: 14,
      ),
    );

    return true;
  }

  // --- KẾT THÚC HÀM MỚI ---

  /// 📍 Định vị người dùng + điền vào ô “Địa chỉ bắt đầu”

  Future<bool> _locateMe() async {
    bool serviceEnabled;

    LocationPermission permission;

    // Kiểm tra dịch vụ

    serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      _showSnack("Vui lòng bật GPS");

      return false;
    }

    // Kiểm tra quyền

    permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();

      if (permission == LocationPermission.denied) {
        _showSnack("Bạn đã từ chối quyền vị trí");

        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnack("Quyền vị trí bị chặn vĩnh viễn");

      return false;
    }

    // Lấy vị trí hiện tại

    final pos = await Geolocator.getCurrentPosition();

    // 🔄 Lấy địa chỉ từ tọa độ

    final address = await _reverseGeocode(pos.latitude, pos.longitude);

    if (address != null) {
      setState(() {
        _startCtrl.text = address;
      });
    }

    // Thêm marker

    await _pointManager?.deleteAll();

    await _pointManager?.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates: mapbox.Position(pos.longitude, pos.latitude),
        ),

        textField: "Vị trí của bạn",

        textSize: 14,
      ),
    );

    // Di chuyển camera

    await _mapboxMap?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(pos.longitude, pos.latitude),
        ),

        zoom: 15,
      ),

      mapbox.MapAnimationOptions(duration: 1000),
    );

    return true;
  }

  /// Tính góc (bearing) giữa 2 điểm

  double _calculateBearing(mapbox.Position start, mapbox.Position end) {
    final double startLat = start.lat * (math.pi / 180.0);

    final double startLng = start.lng * (math.pi / 180.0);

    final double endLat = end.lat * (math.pi / 180.0);

    final double endLng = end.lng * (math.pi / 180.0);

    double dLng = endLng - startLng;

    double y = math.sin(dLng) * math.cos(endLat);

    double x =
        math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(dLng);

    double brng = math.atan2(y, x);

    return (brng * (180.0 / math.pi) + 360) % 360; // Convert to degrees
  }

  // --- HÀM MỚI: BẮT ĐẦU NAVIGATION THỰC TẾ ---

  Future<void> _startRealTimeTracking() async {
    if (_routeCoordinates.isEmpty ||
        _mapboxMap == null ||
        _pointManager == null ||
        _polylineManager == null ||
        _destinationCoords == null ||
        _arrowIconData == null) {
      _showSnack("Vui lòng vẽ tuyến đường trước (hoặc icon chưa load xong)");

      return;
    }

    // Kiểm tra quyền vị trí

    final hasPermission = await _locateMe();

    if (!hasPermission) return;

    if (_isNavigating) return; // Đã chạy rồi thì thôi

    setState(() {
      _isNavigating = true;
    });

    _showSnack("Bắt đầu điều hướng!");

    // Xoá marker xe hơi cũ (nếu có)

    if (_userLocationMarker != null) {
      await _pointManager?.delete(_userLocationMarker!);

      _userLocationMarker = null;
    }

    // Tạo marker mũi tên mới tại điểm bắt đầu

    _userLocationMarker = await _pointManager!.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: _routeCoordinates.first),

        image: _arrowIconData!,

        iconSize: 0.1,

        iconRotate: 0.0,
      ),
    );

    // Lắng nghe stream vị trí

    _locationSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, // Yêu cầu độ chính xác cao

            distanceFilter: 10, // Cập nhật khi di chuyển ít nhất 10 mét
          ),
        ).listen(
          (Position userGpsPos) {
            // Đây là nơi xử lý logic chính

            _updateNavigation(userGpsPos);
          },
          onError: (e) {
            _showSnack("Lỗi GPS: $e");

            _stopRealTimeTracking();
          },
        );
  }

  // --- HÀM MỚI: DỪNG NAVIGATION ---

  Future<void> _stopRealTimeTracking() async {
    // Huỷ lắng nghe stream

    await _locationSubscription?.cancel();

    _locationSubscription = null;

    setState(() {
      _isNavigating = false;
    });

    // (Tùy chọn) Xóa marker xe

    // if (_userLocationMarker != null) {

    //   await _pointManager?.delete(_userLocationMarker!);

    //   _userLocationMarker = null;

    // }
  }

  // --- HÀM MỚI: LOGIC ĐIỀU HƯỚNG CHÍNH ---

  /// Hàm này được gọi MỖI KHI có vị trí GPS mới

  Future<void> _updateNavigation(Position userGpsPos) async {
    if (!_isNavigating ||
        _userLocationMarker == null ||
        _routePolyline == null) {
      return;
    }

    final currentUserPos = mapbox.Position(
      userGpsPos.longitude,
      userGpsPos.latitude,
    );

    // ===== IN VỊ TRÍ GPS TỪ GEOLOCATOR =====

    print(
      "--- [GPS] Vị trí GPS hiện tại: Lng: ${currentUserPos.lng.toDouble()}, Lat: ${currentUserPos.lat.toDouble()} ---",
    );

    // =============================================

    // --- LOGIC SNAP-TO-ROAD (Đơn giản) ---

    // Tìm điểm gần nhất trên tuyến đường so với vị trí GPS của người dùng

    int closestPointIndex = -1;

    double minDistance = double.maxFinite;

    for (int i = 0; i < _routeCoordinates.length; i++) {
      final pointOnRoute = _routeCoordinates[i];

      final distance = Geolocator.distanceBetween(
        currentUserPos.lat.toDouble(),

        currentUserPos.lng.toDouble(),

        pointOnRoute.lat.toDouble(),

        pointOnRoute.lng.toDouble(),
      );

      if (distance < minDistance) {
        minDistance = distance;

        closestPointIndex = i;
      }
    }

    // --- LOGIC PHÁT HIỆN ĐI LẠC (OFF-ROUTE) ---

    if (minDistance > OFF_ROUTE_THRESHOLD && _destinationCoords != null) {
      _showSnack("Bạn đã đi lạc! Đang tìm lại đường...");

      // Dừng stream cũ

      await _stopRealTimeTracking();

      // Gọi API vẽ đường mới từ vị trí hiện tại -> điểm đến cũ

      final success = await _fetchAndDrawRoute(
        currentUserPos,
        _destinationCoords!,
      );

      if (success) {
        // Bắt đầu lại navigation với tuyến đường mới

        await _startRealTimeTracking();
      } else {
        _showSnack("Không thể tìm lại đường mới.");
      }

      return; // Dừng xử lý vị trí này
    }

    // --- CẬP NHẬT UI (NẾU VẪN ĐÚNG ĐƯỜNG) ---

    // 1. Lấy vị trí đã "khớp" (snapped)

    final snappedPosition = _routeCoordinates[closestPointIndex];

    double bearing = 0.0;

    // 2. Tính hướng

    if (closestPointIndex < _routeCoordinates.length - 1) {
      final nextPoint = _routeCoordinates[closestPointIndex + 1];

      bearing = _calculateBearing(snappedPosition, nextPoint);
    } else {
      bearing = _userLocationMarker!.iconRotate ?? 0.0;
    }

    // 3. Cập nhật vị trí và HƯỚNG của marker

    _userLocationMarker!.geometry = mapbox.Point(coordinates: snappedPosition);

    _userLocationMarker!.iconRotate = bearing;

    await _pointManager!.update(_userLocationMarker!);

    // 4. Cập nhật (rút ngắn) đường polyline

    final remainingCoords = _routeCoordinates.sublist(closestPointIndex);

    _routePolyline!.geometry = mapbox.LineString(coordinates: remainingCoords);

    await _polylineManager!.update(_routePolyline!);

    // 5. Di chuyển camera

    await _mapboxMap!.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: snappedPosition),

        zoom: 16,

        bearing: bearing, // Xoay camera
      ),

      mapbox.MapAnimationOptions(duration: 500),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    // Nhớ huỷ stream khi widget bị huỷ

    _locationSubscription?.cancel();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Goong Map - Realtime Navigation"),

        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),

            onPressed: _locateMe,

            tooltip: "Định vị tôi",
          ),
        ],
      ),

      body: Column(
        children: [
          // ô nhập địa chỉ
          Padding(
            padding: const EdgeInsets.all(8.0),

            child: Column(
              children: [
                TextField(
                  controller: _startCtrl,

                  decoration: const InputDecoration(
                    labelText: "Địa chỉ bắt đầu",

                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 8),

                TextField(
                  controller: _endCtrl,

                  decoration: const InputDecoration(
                    labelText: "Địa chỉ kết thúc",

                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 8),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,

                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.alt_route),

                      label: const Text("Vẽ tuyến đường"),

                      onPressed: () => _drawRoute(
                        _startCtrl.text.trim(),
                        _endCtrl.text.trim(),
                      ),
                    ),

                    // --- SỬA ĐỔI NÚT NÀY ---
                    ElevatedButton.icon(
                      icon: Icon(_isNavigating ? Icons.stop : Icons.navigation),

                      label: Text(_isNavigating ? "Dừng" : "Bắt đầu"),

                      onPressed: _isIconLoaded
                          ? (_isNavigating
                                ? _stopRealTimeTracking // Nếu đang chạy, bấm để DỪNG
                                : _startRealTimeTracking) // Nếu đang dừng, bấm để CHẠY
                          : null,

                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isNavigating
                            ? Colors.red
                            : Colors.green,

                        disabledBackgroundColor: Colors.grey.shade400,
                      ),
                    ),

                    // --- KẾT THÚC SỬA ĐỔI ---
                  ],
                ),
              ],
            ),
          ),

          // bản đồ
          Expanded(
            child: mapbox.MapWidget(
              key: const ValueKey("mapWidget"),

              styleUri:
                  "https://tiles.goong.io/assets/goong_map_web.json?api_key=$_goongMapKey",

              onMapCreated: _onMapCreated,

              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(
                  coordinates: mapbox.Position(106.700981, 10.776889),
                ),

                zoom: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
