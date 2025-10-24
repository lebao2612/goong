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

  // THÊM 2 DÒNG NÀY
  List<mapbox.Position> _routeCoordinates = []; // Lưu các điểm của tuyến đường
  mapbox.PointAnnotation? _userLocationMarker;  // Marker xe hơi để di chuyển

  // THÊM BIẾN NÀY
  mapbox.PolylineAnnotation? _routePolyline; // Lưu đường line để cập nhật
  // THÊM BIẾN NÀY
  Uint8List? _arrowIconData; // Để lưu dữ liệu ảnh icon

  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();

  final String _goongMapKey = "xxx";
  final String _goongApiKey = "xxx";

  @override
  void initState() {
    super.initState();
    mapbox.MapboxOptions.setAccessToken("pk.xxx");
    _loadIcon(); // GỌI HÀM LOAD ICON
  }

  // THÊM HÀM MỚI NÀY
  /// Load icon từ asset
  Future<void> _loadIcon() async {
    try {
      final ByteData byteData = await rootBundle.load('assets/navigation_arrow.png');
      _arrowIconData = byteData.buffer.asUint8List();
    } catch (e) {
      debugPrint("Lỗi load icon: $e");
    }
  }

  void _onMapCreated(mapbox.MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    _pointManager = await mapboxMap.annotations.createPointAnnotationManager();
    _polylineManager =
        await mapboxMap.annotations.createPolylineAnnotationManager();
  }

  /// 🗺️ Geocode địa chỉ -> toạ độ
  Future<Map<String, double>?> _geocode(String address) async {
    final url = Uri.parse(
        "https://rsapi.goong.io/Geocode?address=$address&api_key=$_goongApiKey");
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
        "https://rsapi.goong.io/Geocode?latlng=$lat,$lng&api_key=$_goongApiKey");
    final res = await http.get(url);
    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body);
    if (data["results"] == null || data["results"].isEmpty) return null;

    return data["results"][0]["formatted_address"];
  }

  /// 🚗 Vẽ tuyến đường từ A -> B
  Future<void> _drawRoute(String start, String end) async {
    if (_mapboxMap == null) return;

    final from = await _geocode(start);
    final to = await _geocode(end);
    if (from == null || to == null) {
      _showSnack("Không tìm thấy địa chỉ");
      return;
    }

    final url = Uri.parse(
        "https://rsapi.goong.io/Direction?origin=${from["lat"]},${from["lng"]}&destination=${to["lat"]},${to["lng"]}&vehicle=car&api_key=$_goongApiKey");
    final res = await http.get(url);
    if (res.statusCode != 200) {
      _showSnack("Không lấy được tuyến đường");
      return;
    }

    final data = jsonDecode(res.body);
    if (data["routes"] == null || data["routes"].isEmpty) {
      _showSnack("Không tìm thấy tuyến đường");
      return;
    }

    final encoded = data["routes"][0]["overview_polyline"]["points"];
    final routePoints = PolylinePoints.decodePolyline(encoded);
    final coords = routePoints
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();

    // Lưu lại tuyến đường để demo
    _routeCoordinates = coords;

    // Xoá cũ
    await _polylineManager?.deleteAll();
    await _pointManager?.deleteAll();

    // -- SỬA ĐỔI Ở ĐÂY --
    _userLocationMarker = null;
    _routePolyline = null; // Reset polyline
    // -- KẾT THÚC SỬA ĐỔI --

    // Vẽ line
    // await _polylineManager?.create(
    //   mapbox.PolylineAnnotationOptions(
    //     geometry: mapbox.LineString(coordinates: coords),
    //     lineColor: Colors.blue.value,
    //     lineWidth: 5.0,
    //   ),
    // );

    // -- SỬA ĐỔI Ở ĐÂY --
    _routePolyline = await _polylineManager?.create( // Gán vào biến
      mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: coords),
        lineColor: Colors.blue.value,
        lineWidth: 5.0,
      ),
    );
    // -- KẾT THÚC SỬA ĐỔI --

    // Thêm marker Start - End
    await _pointManager?.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(from["lng"]!, from["lat"]!),
      ),
      textField: "Start",
      textSize: 14,
    ));
    await _pointManager?.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(to["lng"]!, to["lat"]!),
      ),
      textField: "End",
      textSize: 14,
    ));

    // Focus camera
    await _mapboxMap?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
              (from["lng"]! + to["lng"]!) / 2, (from["lat"]! + to["lat"]!) / 2),
        ),
        zoom: 12,
      ),
      mapbox.MapAnimationOptions(duration: 1000),
    );
  }

  /// 📍 Định vị người dùng + điền vào ô “Địa chỉ bắt đầu”
  Future<void> _locateMe() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Kiểm tra dịch vụ
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnack("Vui lòng bật GPS");
      return;
    }

    // Kiểm tra quyền
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnack("Bạn đã từ chối quyền vị trí");
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnack("Quyền vị trí bị chặn vĩnh viễn");
      return;
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
    await _pointManager?.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(pos.longitude, pos.latitude),
      ),
      textField: "Vị trí của bạn",
      textSize: 14,
    ));

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
  }

  /// Tính góc (bearing) giữa 2 điểm
  double _calculateBearing(mapbox.Position start, mapbox.Position end) {
    final double startLat = start.lat * (math.pi / 180.0);
    final double startLng = start.lng * (math.pi / 180.0);
    final double endLat = end.lat * (math.pi / 180.0);
    final double endLng = end.lng * (math.pi / 180.0);

    double dLng = endLng - startLng;
    double y = math.sin(dLng) * math.cos(endLat);
    double x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(dLng);

    double brng = math.atan2(y, x);
    return (brng * (180.0 / math.pi) + 360) % 360; // Convert to degrees
  }

  // THÊM HÀM MỚI NÀY
  /// 🚗 Bắt đầu Demo di chuyển
  Future<void> _startMockTracking() async {
    if (_routeCoordinates.isEmpty || 
        _mapboxMap == null || 
        _pointManager == null || 
        _polylineManager == null ||
        _arrowIconData == null) {
      _showSnack("Vui lòng vẽ tuyến đường trước (hoặc icon chưa load xong)");
      return;
    }

    // Xoá marker xe hơi cũ nếu có
    if (_userLocationMarker != null) {
      await _pointManager?.delete(_userLocationMarker!);
      _userLocationMarker = null;
    }

    // -- SỬA ĐỔI MARKER TỪ ĐÂY --
    // Tạo marker mũi tên mới tại điểm bắt đầu
    _userLocationMarker = await _pointManager!.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: _routeCoordinates.first),
        // DÙNG IMAGE THAY VÌ TEXT
        image: _arrowIconData!, 
        iconSize: 0.1, // Kích thước (1.0 là gốc, 2.0 là gấp đôi...)
        iconRotate: 0.0, // Xoay ban đầu
      ),
    );
    // -- KẾT THÚC SỬA ĐỔI MARKER --

    if (_userLocationMarker == null) return;

    // Lặp qua từng điểm trên tuyến đường
    // -- SỬA ĐỔI VÒNG LẶP TỪ ĐÂY --
    for (int i = 0; i < _routeCoordinates.length; i++) {
      // Nếu marker hoặc line bị xoá (do vẽ lại), dừng demo
      if (_userLocationMarker == null || _routePolyline == null) break;

      final currentPoint = _routeCoordinates[i];
      double bearing = 0.0; // Hướng mặc định

      // Tính hướng nếu đây không phải là điểm cuối cùng
      if (i < _routeCoordinates.length - 1) {
        final nextPoint = _routeCoordinates[i + 1];
        bearing = _calculateBearing(currentPoint, nextPoint);
      } else {
        // Nếu là điểm cuối, giữ nguyên hướng của đoạn trước đó
        bearing = _userLocationMarker!.iconRotate ?? 0.0;
      }

      // 1. Cập nhật vị trí và HƯỚNG của marker
      _userLocationMarker!.geometry = mapbox.Point(coordinates: currentPoint);
      _userLocationMarker!.iconRotate = bearing; // QUAN TRỌNG: xoay icon
      await _pointManager!.update(_userLocationMarker!);

      // 2. Cập nhật (rút ngắn) đường polyline
      final remainingCoords = _routeCoordinates.sublist(i); // Lấy các điểm còn lại
      _routePolyline!.geometry = mapbox.LineString(coordinates: remainingCoords);
      await _polylineManager!.update(_routePolyline!);

      // 3. Di chuyển camera theo marker VÀ XOAY camera
      await _mapboxMap!.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(coordinates: currentPoint),
          zoom: 16,
          bearing: bearing, // QUAN TRỌNG: xoay camera
        ),
        mapbox.MapAnimationOptions(duration: 100), // Di chuyển camera mượt
      );

      // Đợi 1 chút trước khi đến điểm tiếp theo
      await Future.delayed(const Duration(seconds: 1));
    }
    // -- KẾT THÚC SỬA ĐỔI VÒNG LẶP --

    _showSnack("Đã hoàn thành demo!");
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Goong Map Routing + Định vị tự động"),
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
                          _startCtrl.text.trim(), _endCtrl.text.trim()),
                    ),
                    
                    // THÊM NÚT NÀY
                    ElevatedButton.icon(
                      icon: const Icon(Icons.drive_eta),
                      label: const Text("Demo Tracking"),
                      onPressed: _startMockTracking, // Gọi hàm demo
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green, // Đổi màu cho dễ thấy
                      ),
                    ),
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
