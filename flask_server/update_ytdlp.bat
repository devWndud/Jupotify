@echo off
echo ========================================
echo yt-dlp 업데이트 및 YouTube 차단 우회 설정
echo ========================================
echo.

echo 현재 yt-dlp 버전 확인...
yt-dlp --version

echo.
echo 기존 yt-dlp 제거 중...
pip uninstall yt-dlp -y

echo.
echo 최신 버전 설치 중...
pip install --upgrade yt-dlp

echo.
echo 새 버전 확인...
yt-dlp --version

echo.
echo YouTube 차단 우회를 위한 추가 설정...
echo - User-Agent 로테이션 활성화
echo - 다중 클라이언트 지원 (Android Music, iOS)
echo - 재시도 로직 강화
echo - 시그니처 추출 우회

echo.
echo 서버를 재시작하여 새 설정을 적용하세요.
echo.
echo 문제가 지속되면 다음을 시도하세요:
echo 1. VPN 사용
echo 2. 다른 서버 사용
echo 3. 쿠키 파일 사용
echo.
pause
