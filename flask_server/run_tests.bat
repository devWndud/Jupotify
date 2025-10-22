@echo off
echo yt-dlp 테스트 스크립트들
echo.

echo 1. 비디오 정보만 가져오기 테스트
python test_info.py
echo.

echo 2. 간단한 다운로드 테스트
python test_simple.py
echo.

echo 3. 상세한 다운로드 테스트
python test_ytdlp.py https://www.youtube.com/watch?v=eefC4-IHZoA
echo.

pause
