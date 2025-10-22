import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class FavoritesService {
  static const String _key = 'jupofavorites';
  static final FavoritesService _instance = FavoritesService._internal();
  factory FavoritesService() => _instance;
  FavoritesService._internal();

  final StreamController<Set<String>> _controller = StreamController<Set<String>>.broadcast();
  Set<String> _cache = <String>{};
  bool _initialized = false;

  Stream<Set<String>> get stream => _controller.stream;

  Future<void> _ensureLoaded() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? const <String>[];
    _cache = list.toSet();
    _initialized = true;
    _controller.add(_cache);
  }

  Future<Set<String>> getAll() async {
    await _ensureLoaded();
    return _cache;
  }

  Future<bool> isFavorite(String id) async {
    await _ensureLoaded();
    return _cache.contains(id);
  }

  Future<void> toggle(String id) async {
    await _ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    if (_cache.contains(id)) {
      _cache.remove(id);
    } else {
      _cache.add(id);
    }
    await prefs.setStringList(_key, _cache.toList());
    _controller.add(_cache);
  }
}


