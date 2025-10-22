# 🔒 Jupotify Flask 서버 보안 가이드

## 🚨 현재 보안 위험

로그 분석 결과, 다음과 같은 보안 위험이 감지되었습니다:

### 감지된 공격 패턴
- **SSL/TLS 공격**: 암호화된 요청이 HTTP 서버로 전송
- **PowerShell 다운로드 시도**: `GET /download/powershell/`
- **PHP 스크립트 접근**: `GET /get.php`
- **일반적인 봇/스캐너 접근**: 다양한 IP에서 404 에러 발생

## 🛡️ 적용된 보안 조치

### 1. Rate Limiting
```python
# 엔드포인트별 제한
/extract: 5 requests/minute
/download: 3 requests/minute
/files/: 20 requests/minute
/delete: 10 requests/minute
```

### 2. 의심스러운 패턴 감지
- PowerShell, CMD, Bash 명령어 차단
- PHP, ASP, JSP 스크립트 접근 차단
- 관리자 패널 접근 시도 차단
- 데이터베이스 관련 접근 차단

### 3. IP 기반 차단
- 10회 이상 의심스러운 요청 시 1시간 차단
- 실시간 의심스러운 활동 모니터링

### 4. 엔드포인트 화이트리스트
허용된 엔드포인트만 접근 가능:
- `/extract` - 비디오 정보 추출
- `/download` - 파일 다운로드
- `/files/` - 파일 제공
- `/delete` - 파일 삭제
- `/version` - 버전 체크
- `/health` - 헬스체크

## 🚀 보안 서버 실행 방법

### 1. 기본 실행
```bash
# 의존성 설치
pip install -r requirements.txt

# 보안 서버 시작
python start_secure_server.py
```

### 2. Docker 실행 (권장)
```bash
# Docker Compose로 전체 스택 실행
docker-compose up -d

# 보안 모니터링 시작
docker-compose exec security-monitor python security_monitor.py
```

### 3. Nginx 프록시 사용 (프로덕션)
```bash
# Nginx 설정 복사
sudo cp nginx.conf /etc/nginx/sites-available/jupotify
sudo ln -s /etc/nginx/sites-available/jupotify /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## 📊 보안 모니터링

### 실시간 모니터링
```bash
# 보안 모니터 실행
python security_monitor.py

# 로그 실시간 확인
tail -f server.log
```

### 로그 분석
```bash
# 의심스러운 IP 확인
grep "Suspicious request" server.log | cut -d' ' -f8 | sort | uniq -c

# 차단된 IP 확인
grep "Blocking suspicious IP" server.log
```

## 🔧 추가 보안 설정

### 1. 방화벽 설정
```bash
# UFW 방화벽 설정
sudo ufw enable
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw deny 8080/tcp   # Flask 서버 직접 접근 차단
```

### 2. Fail2ban 설정
```bash
# /etc/fail2ban/jail.local
[flask-server]
enabled = true
port = 8080
filter = flask-server
logpath = /path/to/server.log
maxretry = 5
bantime = 3600
```

### 3. SSL/TLS 인증서 설정
```bash
# Let's Encrypt 인증서 발급
sudo certbot --nginx -d your-domain.com
```

## 📈 성능 모니터링

### 메모리 사용량 확인
```bash
# 컨테이너 리소스 사용량
docker stats jupotify-secure-server
```

### 로그 로테이션 설정
```bash
# /etc/logrotate.d/jupotify
/path/to/server.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 jupotify jupotify
}
```

## 🚨 응급 상황 대응

### 1. 대량 공격 감지 시
```bash
# 서버 즉시 중지
docker-compose down

# IP 차단 목록 확인
grep "Blocking suspicious IP" server.log

# 방화벽으로 IP 차단
sudo ufw deny from <suspicious-ip>
```

### 2. 서버 복구
```bash
# 백업에서 복원
docker-compose up -d

# 보안 설정 재적용
python security_monitor.py
```

## 📞 지원 및 문의

보안 관련 문제 발생 시:
1. 로그 파일 확인
2. 보안 모니터 실행
3. 필요시 서버 재시작
4. 추가 보안 조치 적용

---

**⚠️ 중요**: 이 서버는 공개 인터넷에 노출되어 있으므로 지속적인 보안 모니터링이 필요합니다.
