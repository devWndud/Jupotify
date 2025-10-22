import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/version_checker.dart';

class UpdateDialog extends StatelessWidget {
  final VersionInfo versionInfo;

  const UpdateDialog({
    super.key,
    required this.versionInfo,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            versionInfo.forceUpdate ? Icons.warning : Icons.system_update,
            color: versionInfo.forceUpdate ? Colors.orange : Colors.blue,
          ),
          const SizedBox(width: 8),
          Text(
            versionInfo.forceUpdate ? '필수 업데이트' : '업데이트 사용 가능',
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '현재 버전: ${versionInfo.currentVersion}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            '최신 버전: ${versionInfo.latestVersion}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (versionInfo.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              '업데이트 내용:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(versionInfo.releaseNotes),
          ],
        ],
      ),
      actions: [
        if (!versionInfo.forceUpdate)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('나중에'),
          ),
        ElevatedButton(
          onPressed: () => _launchDownloadUrl(context),
          child: const Text('업데이트'),
        ),
      ],
    );
  }

  Future<void> _launchDownloadUrl(BuildContext context) async {
    if (versionInfo.downloadUrl.isNotEmpty) {
      try {
        final uri = Uri.parse(versionInfo.downloadUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('다운로드 링크를 열 수 없습니다.'),
              ),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('오류: $e'),
            ),
          );
        }
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('다운로드 링크가 설정되지 않았습니다.'),
          ),
        );
      }
    }
  }
}
