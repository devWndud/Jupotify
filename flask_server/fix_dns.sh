#!/bin/bash
# DNS 문제 해결 스크립트

echo "🔧 DNS 문제 해결 시작"
echo "========================"

# 현재 DNS 설정 확인
echo "현재 DNS 설정:"
cat /etc/resolv.conf

echo ""
echo "DNS 서버 테스트:"
nslookup www.youtube.com
nslookup youtube.com
nslookup www.google.com

echo ""
echo "Google DNS로 변경 중..."

# 백업 생성
cp /etc/resolv.conf /etc/resolv.conf.backup

# Google DNS 설정
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

echo "새 DNS 설정:"
cat /etc/resolv.conf

echo ""
echo "DNS 테스트:"
nslookup www.youtube.com
nslookup youtube.com

echo ""
echo "네트워크 재시작 중..."
systemctl restart networking 2>/dev/null || service networking restart 2>/dev/null || true

echo ""
echo "최종 테스트:"
ping -c 3 8.8.8.8
ping -c 3 www.youtube.com

echo ""
echo "✅ DNS 설정 완료!"
echo "서버를 재시작하세요: python start_secure_server.py"
