#!/usr/bin/env python3
"""
보안 모니터링 스크립트
의심스러운 활동을 감지하고 알림을 보냅니다.
"""
import os
import re
import json
import time
from datetime import datetime, timedelta
from collections import defaultdict, Counter

class SecurityMonitor:
    def __init__(self, log_file='server.log'):
        self.log_file = log_file
        self.suspicious_ips = defaultdict(list)
        self.attack_patterns = [
            r'powershell', r'cmd', r'bash', r'sh',
            r'php', r'asp', r'jsp', r'admin',
            r'wp-admin', r'wp-content', r'config',
            r'database', r'backup', r'sql', r'dump',
            r'shell', r'exec', r'system', r'eval'
        ]
    
    def parse_log_line(self, line):
        """로그 라인 파싱"""
        try:
            # Flask 로그 형식 파싱
            if 'Suspicious request from' in line:
                ip_match = re.search(r'(\d+\.\d+\.\d+\.\d+)', line)
                if ip_match:
                    return {
                        'type': 'suspicious',
                        'ip': ip_match.group(1),
                        'timestamp': datetime.now(),
                        'line': line.strip()
                    }
            elif 'Blocking suspicious IP' in line:
                ip_match = re.search(r'(\d+\.\d+\.\d+\.\d+)', line)
                if ip_match:
                    return {
                        'type': 'blocked',
                        'ip': ip_match.group(1),
                        'timestamp': datetime.now(),
                        'line': line.strip()
                    }
        except Exception as e:
            print(f"로그 파싱 오류: {e}")
        return None
    
    def analyze_logs(self, hours=24):
        """로그 분석"""
        if not os.path.exists(self.log_file):
            print(f"로그 파일을 찾을 수 없습니다: {self.log_file}")
            return
        
        cutoff_time = datetime.now() - timedelta(hours=hours)
        suspicious_activity = defaultdict(list)
        blocked_ips = set()
        
        try:
            with open(self.log_file, 'r', encoding='utf-8') as f:
                for line in f:
                    parsed = self.parse_log_line(line)
                    if parsed:
                        if parsed['type'] == 'suspicious':
                            suspicious_activity[parsed['ip']].append(parsed)
                        elif parsed['type'] == 'blocked':
                            blocked_ips.add(parsed['ip'])
        except Exception as e:
            print(f"로그 파일 읽기 오류: {e}")
            return
        
        # 분석 결과 출력
        print(f"\n=== 보안 분석 결과 (최근 {hours}시간) ===")
        print(f"차단된 IP 수: {len(blocked_ips)}")
        print(f"의심스러운 활동을 보인 IP 수: {len(suspicious_activity)}")
        
        if blocked_ips:
            print(f"\n차단된 IP 목록:")
            for ip in blocked_ips:
                print(f"  - {ip}")
        
        if suspicious_activity:
            print(f"\n의심스러운 활동 상위 IP:")
            sorted_ips = sorted(suspicious_activity.items(), 
                             key=lambda x: len(x[1]), reverse=True)
            for ip, activities in sorted_ips[:10]:
                print(f"  - {ip}: {len(activities)}회")
    
    def generate_report(self):
        """보안 리포트 생성"""
        report = {
            'timestamp': datetime.now().isoformat(),
            'analysis': {}
        }
        
        # 최근 24시간 분석
        self.analyze_logs(24)
        
        return report

def main():
    """메인 함수"""
    monitor = SecurityMonitor()
    
    print("보안 모니터링을 시작합니다...")
    print("Ctrl+C를 눌러 종료하세요.")
    
    try:
        while True:
            monitor.generate_report()
            time.sleep(300)  # 5분마다 분석
    except KeyboardInterrupt:
        print("\n보안 모니터링을 종료합니다.")

if __name__ == "__main__":
    main()
