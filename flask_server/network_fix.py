#!/usr/bin/env python3
"""
네트워크 문제 해결 스크립트
DNS 해결 문제와 YouTube 접근 문제를 해결합니다.
"""
import os
import subprocess
import socket
import requests
from urllib.parse import urlparse

def check_dns_resolution():
    """DNS 해결 상태 확인"""
    test_domains = [
        'www.youtube.com',
        'youtube.com',
        'music.youtube.com',
        'www.google.com'
    ]
    
    print("=== DNS 해결 상태 확인 ===")
    for domain in test_domains:
        try:
            ip = socket.gethostbyname(domain)
            print(f"✅ {domain} -> {ip}")
        except socket.gaierror as e:
            print(f"❌ {domain} -> DNS 해결 실패: {e}")
    
    return True

def check_youtube_access():
    """YouTube 접근 상태 확인"""
    test_urls = [
        'https://www.youtube.com',
        'https://music.youtube.com',
        'https://www.google.com'
    ]
    
    print("\n=== YouTube 접근 상태 확인 ===")
    for url in test_urls:
        try:
            response = requests.get(url, timeout=10)
            print(f"✅ {url} -> HTTP {response.status_code}")
        except requests.exceptions.RequestException as e:
            print(f"❌ {url} -> 접근 실패: {e}")
    
    return True

def fix_dns_settings():
    """DNS 설정 수정"""
    print("\n=== DNS 설정 수정 ===")
    
    # Google DNS 사용
    dns_servers = [
        "8.8.8.8",
        "8.8.4.4",
        "1.1.1.1",
        "1.0.0.1"
    ]
    
    print("권장 DNS 서버:")
    for dns in dns_servers:
        print(f"  - {dns}")
    
    print("\n수동 DNS 설정 방법:")
    print("1. /etc/resolv.conf 파일 수정")
    print("2. nameserver 8.8.8.8 추가")
    print("3. nameserver 8.8.4.4 추가")
    
    return True

def test_ytdlp_direct():
    """yt-dlp 직접 테스트"""
    print("\n=== yt-dlp 직접 테스트 ===")
    
    test_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"  # Rick Roll (안전한 테스트)
    
    try:
        result = subprocess.run([
            'yt-dlp', 
            '--get-title', 
            '--get-duration',
            test_url
        ], capture_output=True, text=True, timeout=30)
        
        if result.returncode == 0:
            print(f"✅ yt-dlp 직접 테스트 성공")
            print(f"제목: {result.stdout.strip()}")
        else:
            print(f"❌ yt-dlp 직접 테스트 실패")
            print(f"오류: {result.stderr}")
            
    except subprocess.TimeoutExpired:
        print("❌ yt-dlp 테스트 시간 초과")
    except FileNotFoundError:
        print("❌ yt-dlp가 설치되지 않음")
    except Exception as e:
        print(f"❌ yt-dlp 테스트 오류: {e}")

def main():
    """메인 함수"""
    print("🔧 네트워크 문제 진단 및 해결")
    print("=" * 50)
    
    # DNS 해결 확인
    check_dns_resolution()
    
    # YouTube 접근 확인
    check_youtube_access()
    
    # DNS 설정 수정 안내
    fix_dns_settings()
    
    # yt-dlp 직접 테스트
    test_ytdlp_direct()
    
    print("\n=== 해결 방안 ===")
    print("1. DNS 서버 변경 (8.8.8.8, 1.1.1.1)")
    print("2. VPN 사용")
    print("3. 프록시 서버 사용")
    print("4. yt-dlp 최신 버전으로 업데이트")
    print("5. 서버 재시작")

if __name__ == "__main__":
    main()
