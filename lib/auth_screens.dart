import 'package:flutter/material.dart';
import 'services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  final VoidCallback onGoSignup;
  const LoginScreen({required this.onLoggedIn, required this.onGoSignup, super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Jupotify', style: TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('로그인', style: TextStyle(fontSize: 16, color: Colors.white70)),
                  const SizedBox(height: 24),
                  _AuthField(
                    controller: _username,
                    label: '이름',
                    icon: Icons.person_outline,
                  ),
                  const SizedBox(height: 12),
                  _AuthField(
                    controller: _password,
                    label: '비밀번호',
                    icon: Icons.lock_outline,
                    obscure: true,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.12),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _loading ? null : () async {
                    setState(() { _loading = true; _error = null; });
                    try {
                      await AuthService().login(username: _username.text, password: _password.text);
                      widget.onLoggedIn();
                    } catch (e) {
                      final msg = e.toString();
                      // Simplify common auth errors for users
                      String friendly = msg;
                      if (msg.contains('The password is invalid')) {
                        friendly = '아이디 또는 비밀번호가 올바르지 않습니다.';
                      } else if (msg.contains('no user record')) {
                        friendly = '존재하지 않는 계정입니다.';
                      } else if (msg.contains('이 계정은 다른 기기에 이미 연결되어 있습니다')) {
                        friendly = '이 계정은 다른 기기에 이미 연결되어 있습니다.';
                      }
                      setState(() { _error = friendly; });
                    } finally {
                      setState(() { _loading = false; });
                    }
                      },
                      child: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('로그인'),
                    ),
                  ),
                  TextButton(onPressed: widget.onGoSignup, child: const Text('회원가입', style: TextStyle(color: Colors.white70))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SignupScreen extends StatefulWidget {
  final VoidCallback onGoLogin;
  const SignupScreen({required this.onGoLogin, super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Jupotify', style: TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('회원가입', style: TextStyle(fontSize: 16, color: Colors.white70)),
                  const SizedBox(height: 24),
                  _AuthField(controller: _username, label: '이름', icon: Icons.person_outline),
                  const SizedBox(height: 12),
                  _AuthField(controller: _password, label: '비밀번호', icon: Icons.lock_outline, obscure: true),
                  const SizedBox(height: 12),
                  _AuthField(controller: _confirm, label: '비밀번호 확인', icon: Icons.lock_outline, obscure: true),
                  const SizedBox(height: 12),
                  if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.12),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                  onPressed: _loading ? null : () async {
                    setState(() { _loading = true; _error = null; });
                    try {
                      if (_password.text != _confirm.text) {
                        throw Exception('비밀번호 확인이 일치하지 않습니다.');
                      }
                      await AuthService().signup(username: _username.text, password: _password.text);
                      if (!mounted) return;
                      // 가입 신청 완료 후 강제 로그아웃 상태이므로 승인 대기 안내
                      showDialog(context: context, builder: (_) => AlertDialog(
                        title: const Text('신청 완료'),
                        content: const Text('관리자 승인 후 로그인하세요.'),
                        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인'))],
                      ));
                      widget.onGoLogin();
                    } catch (e) {
                      setState(() { _error = e.toString(); });
                    } finally {
                      setState(() { _loading = false; });
                    }
                      },
                      child: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('가입 신청'),
                    ),
                  ),
                  TextButton(onPressed: widget.onGoLogin, child: const Text('로그인으로', style: TextStyle(color: Colors.white70))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('관리자 승인')),
      body: StreamBuilder(
        stream: AuthService().pendingUsersStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final qs = snapshot.data! as dynamic;
          final docs = qs.docs as List;
          if (docs.isEmpty) return const Center(child: Text('대기 중인 신청이 없습니다.'));
          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final d = docs[i];
              final data = d.data() as Map<String, dynamic>;
              return ListTile(
                title: Text(data['username'] ?? ''),
                trailing: ElevatedButton(
                  onPressed: () => AuthService().setApproved(d.id, true),
                  child: const Text('승인'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  const _AuthField({required this.controller, required this.label, required this.icon, this.obscure = false});
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        prefixIcon: Icon(icon, color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.08),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white54),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
    );
  }
}


