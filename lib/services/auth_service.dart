import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Convert username to an email-like identifier (no external email sending)
  String _usernameToEmail(String username) => '${username.trim()}@local.auth';

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  Future<UserCredential> signup({required String username, required String password}) async {
    final email = _usernameToEmail(username);
    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    final deviceId = await _getStableDeviceId();
    await _db.collection('users').doc(cred.user!.uid).set({
      'username': username.trim(),
      'approved': false,
      'deviceId': deviceId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await _auth.signOut(); // prevent using app before approval
    return cred;
  }

  Future<UserCredential> login({required String username, required String password}) async {
    final email = _usernameToEmail(username);
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    final doc = await _db.collection('users').doc(cred.user!.uid).get();
    final approved = (doc.data()?['approved'] as bool?) ?? false;
    if (!approved) {
      await _auth.signOut();
      throw Exception('승인 대기 중입니다. 관리자 승인 후 이용 가능합니다.');
    }
    final bound = doc.data()?['deviceId'] as String?;
    final currentDevice = await _getStableDeviceId();
    if (bound == null || bound.isEmpty) {
      // First login after approval: bind to this device
      await _db.collection('users').doc(cred.user!.uid).update({'deviceId': currentDevice});
    } else if (bound != currentDevice) {
      await _auth.signOut();
      throw Exception('이 계정은 다른 기기에 이미 연결되어 있습니다.');
    }
    return cred;
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  Future<bool> isApproved(User user) async {
    final doc = await _db.collection('users').doc(user.uid).get();
    return (doc.data()?['approved'] as bool?) ?? false;
  }

  Future<String?> getCurrentUsername() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final doc = await _db.collection('users').doc(user.uid).get();
    return doc.data()?['username'] as String?;
  }

  Future<bool> isCurrentUserAdmin() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    final doc = await _db.collection('users').doc(user.uid).get();
    return (doc.data()?['admin'] as bool?) ?? false;
  }

  // Admin: approve user
  Future<void> setApproved(String uid, bool value) async {
    await _db.collection('users').doc(uid).update({'approved': value});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> pendingUsersStream() {
    return _db.collection('users').where('approved', isEqualTo: false).snapshots();
  }

  Future<String> _getStableDeviceId() async {
    final info = DeviceInfoPlugin();
    try {
      final android = await info.androidInfo;
      final id = android.id; // hardware id, may change on factory reset
      final androidId = android.id;
      final serial = android.serialNumber;
      return androidId?.isNotEmpty == true
          ? androidId!
          : (id?.isNotEmpty == true ? id! : (serial ?? 'unknown'));
    } catch (_) {
      // Fallback for other platforms
      return 'unknown';
    }
  }
}


