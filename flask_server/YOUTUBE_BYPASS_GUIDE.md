# 🚀 YouTube 차단 우회 가이드

## 🚨 현재 문제
YouTube가 yt-dlp를 차단하여 "HTTP Error 403: Forbidden" 오류가 발생합니다.

## 🛠️ 해결 방안

### 1. 자동 우회 시스템 (이미 구현됨)
서버가 자동으로 다음 방법들을 순차적으로 시도합니다:

1. **Standard 설정**: 기본 yt-dlp 설정
2. **Aggressive 설정**: 더 공격적인 우회 설정
3. **Proxy 설정**: 프록시 서버 사용
4. **Cookie 설정**: YouTube 로그인 쿠키 사용
5. **Proxy + Cookie**: 프록시와 쿠키 조합

### 2. 수동 설정 방법

#### A. 프록시 서버 사용
```bash
# 프록시 목록 파일 생성
echo "http://proxy1:port" > proxies.txt
echo "http://proxy2:port" >> proxies.txt

# 환경 변수로 설정
export PROXY_LIST="http://proxy1:port,http://proxy2:port"
```

#### B. YouTube 쿠키 사용
```bash
# 1. Chrome에서 YouTube에 로그인
# 2. F12 개발자 도구 열기
# 3. Application > Cookies > https://www.youtube.com
# 4. 모든 쿠키를 복사하여 youtube_cookies.txt에 저장
# 5. JSON 형식으로 저장:
{
  "VISITOR_INFO1_LIVE": "cookie_value",
  "YSC": "cookie_value",
  "PREF": "cookie_value"
}
```

#### C. VPN 사용
```bash
# VPN 연결 후 서버 재시작
python start_secure_server.py
```

### 3. 고급 우회 방법

#### A. User-Agent 로테이션
서버가 자동으로 다양한 User-Agent를 사용합니다:
- Chrome (Windows)
- Safari (iOS)
- Android Music App

#### B. 다중 클라이언트 지원
- Android Music
- Android Creator
- iOS
- Web

#### C. 시그니처 추출 우회
- DASH/HLS 스트림 우회
- 다중 플레이어 클라이언트 사용
- 재시도 로직 강화

### 4. 모니터링 및 디버깅

#### 로그 확인
```bash
# 실시간 로그 확인
tail -f server.log

# 성공한 방법 확인
grep "Success with" server.log

# 실패한 방법 확인
grep "failed" server.log
```

#### 성능 모니터링
```bash
# 각 방법별 성공률 확인
python security_monitor.py
```

### 5. 문제 해결

#### 모든 방법이 실패하는 경우
1. **VPN 사용**: 다른 지역의 IP로 접속
2. **다른 서버 사용**: 다른 서버에서 시도
3. **yt-dlp 업데이트**: 최신 버전으로 업데이트
4. **쿠키 갱신**: YouTube 로그인 상태 확인

#### 특정 방법만 실패하는 경우
1. **프록시 문제**: 프록시 서버 상태 확인
2. **쿠키 만료**: YouTube 재로그인 후 쿠키 갱신
3. **네트워크 문제**: 인터넷 연결 상태 확인

### 6. 자동화 스크립트

#### 프록시 테스트
```bash
python -c "
from proxy_support import ProxyManager
pm = ProxyManager()
print('작동하는 프록시:', pm.get_working_proxy())
"
```

#### 쿠키 테스트
```bash
python -c "
from cookie_support import CookieManager
cm = CookieManager()
print('쿠키 유효성:', cm.test_cookies())
"
```

### 7. 성능 최적화

#### 캐시 설정
```bash
# 다운로드된 파일 캐시
mkdir -p downloads/cache
```

#### 재시도 설정
```python
# 더 빠른 재시도
"sleep_interval": 0.5,
"max_sleep_interval": 2,
"retries": 2
```

### 8. 보안 고려사항

#### 프록시 보안
- 신뢰할 수 있는 프록시만 사용
- HTTPS 프록시 우선 사용
- 프록시 인증 정보 보호

#### 쿠키 보안
- 쿠키 파일 권한 설정 (600)
- 정기적인 쿠키 갱신
- 민감한 정보 제거

## 📊 성공률 향상 팁

1. **다양한 방법 조합**: 프록시 + 쿠키 조합 사용
2. **정기적인 업데이트**: yt-dlp 최신 버전 유지
3. **모니터링**: 실시간 성공률 확인
4. **백업 방법**: 여러 우회 방법 준비

## 🚨 주의사항

- YouTube 서비스 약관 준수
- 과도한 요청 방지
- 저작권 존중
- 개인정보 보호

---

**💡 팁**: 문제가 지속되면 여러 방법을 조합하여 사용하세요!
