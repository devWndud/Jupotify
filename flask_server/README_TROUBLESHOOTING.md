# YouTube 다운로드 문제 해결 가이드

## 현재 문제
YouTube가 yt-dlp를 차단하여 "Failed to extract any player response" 오류가 발생합니다.

## 🎯 새로운 다운로드 시스템

서버가 이제 **3단계 폴백 시스템**을 사용합니다:

1. **yt-dlp 모듈 방식** (MP3 변환 포함) - `download_mp3.py` 방식
2. **yt-dlp 실행파일 방식** - 시스템에 설치된 yt-dlp 사용
3. **기존 방식** - 원본 포맷 다운로드 (M4A 등)
4. **최종 폴백** - 비디오 정보만 제공

### 독립 실행 스크립트 사용
```bash
# 직접 다운로드
python download_mp3.py <youtube_url> [output_dir]
```

## 해결 방법

### 1. yt-dlp 업데이트
```bash
# Windows
update_ytdlp.bat

# Linux/Mac
chmod +x update_ytdlp.sh
./update_ytdlp.sh
```

### 2. ffmpeg 설치 확인
MP3 변환을 위해 ffmpeg가 필요합니다:
```bash
# 설치 확인
ffmpeg -version

# Windows: https://ffmpeg.org/download.html
# Linux: sudo apt-get install ffmpeg
# Mac: brew install ffmpeg
```

### 3. 서버 설정 변경
- User-Agent를 최신 Chrome으로 업데이트
- Android Music 클라이언트 우선 사용
- 재시도 간격 조정

### 4. 대체 방법
yt-dlp가 실패하면 서버가 자동으로 다른 방법을 시도합니다.

## 추가 해결책

### A. 다른 서버 사용
현재 서버 IP가 YouTube에 의해 차단되었을 수 있습니다.

### B. VPN 사용
다른 지역의 IP로 접속해보세요.

### C. 쿠키 파일 사용
YouTube에 로그인한 상태의 쿠키를 사용:

```python
# server.py에 추가
"cookies": "cookies.txt",  # YouTube 쿠키 파일 경로
```

### D. 프록시 사용
```python
# server.py에 추가
"proxy": "http://proxy-server:port",
```

## 임시 해결책
1. 로컬에서 yt-dlp 직접 사용
2. 다른 YouTube 다운로더 사용
3. 브라우저 확장 프로그램 사용

## 모니터링
- yt-dlp GitHub 이슈 확인
- YouTube 정책 변경 사항 모니터링
- 정기적인 yt-dlp 업데이트
