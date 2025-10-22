# 보안이 강화된 Flask 서버 Docker 이미지
FROM python:3.11-slim

# 보안을 위한 비루트 사용자 생성
RUN groupadd -r jupotify && useradd -r -g jupotify jupotify

# 작업 디렉토리 설정
WORKDIR /app

# 시스템 패키지 업데이트 및 보안 패치
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        nginx \
        fail2ban \
        ufw \
    && rm -rf /var/lib/apt/lists/*

# Python 의존성 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 애플리케이션 파일 복사
COPY . .

# 권한 설정
RUN chown -R jupotify:jupotify /app && \
    chmod -R 755 /app

# 포트 설정
EXPOSE 8080

# 보안 설정
RUN echo "net.ipv4.ip_forward = 0" >> /etc/sysctl.conf && \
    echo "net.ipv4.conf.all.send_redirects = 0" >> /etc/sysctl.conf && \
    echo "net.ipv4.conf.default.send_redirects = 0" >> /etc/sysctl.conf

# 비루트 사용자로 전환
USER jupotify

# 헬스체크
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# 서버 시작
CMD ["python", "start_secure_server.py"]
