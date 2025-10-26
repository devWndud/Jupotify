@echo off
echo yt-dlp를 최신 버전으로 업데이트 중...

REM 기존 yt-dlp 제거
pip uninstall yt-dlp -y

REM 최신 버전 설치
pip install --upgrade yt-dlp

REM 버전 확인
echo 현재 yt-dlp 버전:
yt-dlp --version

echo 업데이트 완료!
pause
