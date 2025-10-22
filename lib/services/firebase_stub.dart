// Firebase stub for Windows platform
// This file provides mock implementations when Firebase is not available

class Firebase {
  static Future<void> initializeApp() async {
    // No-op for Windows
  }
}

class FirebaseAuth {
  static FirebaseAuth get instance => FirebaseAuth._();
  FirebaseAuth._();
  
  Stream<User?> authStateChanges() => Stream.value(null);
  User? get currentUser => null;
  
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError('Firebase not available on Windows');
  }
  
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError('Firebase not available on Windows');
  }
  
  Future<void> signOut() async {
    // No-op for Windows
  }
}

class FirebaseFirestore {
  static FirebaseFirestore get instance => FirebaseFirestore._();
  FirebaseFirestore._();
  
  CollectionReference<Map<String, dynamic>> collection(String path) {
    throw UnimplementedError('Firebase not available on Windows');
  }
}

class User {
  String get uid => 'windows-user';
}

class UserCredential {
  User? get user => User();
}

class CollectionReference<T> {
  DocumentReference<T> doc(String path) {
    throw UnimplementedError('Firebase not available on Windows');
  }
  
  Query<T> where(String field, {dynamic isEqualTo}) {
    throw UnimplementedError('Firebase not available on Windows');
  }
}

class DocumentReference<T> {
  Future<void> set(Map<String, dynamic> data) async {
    throw UnimplementedError('Firebase not available on Windows');
  }
  
  Future<void> update(Map<String, dynamic> data) async {
    throw UnimplementedError('Firebase not available on Windows');
  }
  
  Future<DocumentSnapshot<T>> get() async {
    throw UnimplementedError('Firebase not available on Windows');
  }
}

class DocumentSnapshot<T> {
  Map<String, dynamic>? data() => null;
}

class Query<T> {
  Stream<QuerySnapshot<T>> snapshots() {
    return Stream.empty();
  }
}

class QuerySnapshot<T> {
  List<QueryDocumentSnapshot<T>> get docs => [];
  int get size => 0;
}

class QueryDocumentSnapshot<T> extends DocumentSnapshot<T> {
  String get id => '';
}

class FieldValue {
  static dynamic serverTimestamp() => DateTime.now().millisecondsSinceEpoch;
}
