#!/usr/bin/env python3
"""
프록시 지원 모듈
YouTube 차단 우회를 위한 프록시 서버 지원
"""
import os
import random
import requests
from typing import List, Dict, Optional

class ProxyManager:
    def __init__(self):
        self.proxies = []
        self.working_proxies = []
        self.failed_proxies = []
        self.load_proxy_list()
    
    def load_proxy_list(self):
        """프록시 목록 로드"""
        # 환경 변수에서 프록시 목록 가져오기
        proxy_list = os.environ.get('PROXY_LIST', '')
        if proxy_list:
            self.proxies = [p.strip() for p in proxy_list.split(',') if p.strip()]
        
        # 파일에서 프록시 목록 로드
        proxy_file = 'proxies.txt'
        if os.path.exists(proxy_file):
            with open(proxy_file, 'r') as f:
                self.proxies.extend([line.strip() for line in f if line.strip()])
        
        print(f"로드된 프록시 수: {len(self.proxies)}")
    
    def test_proxy(self, proxy: str) -> bool:
        """프록시 연결 테스트"""
        try:
            proxies = {
                'http': proxy,
                'https': proxy
            }
            response = requests.get(
                'https://www.youtube.com',
                proxies=proxies,
                timeout=10
            )
            return response.status_code == 200
        except:
            return False
    
    def get_working_proxy(self) -> Optional[str]:
        """작동하는 프록시 반환"""
        # 이미 테스트된 프록시가 있으면 사용
        if self.working_proxies:
            return random.choice(self.working_proxies)
        
        # 새로운 프록시 테스트
        for proxy in self.proxies:
            if proxy not in self.failed_proxies:
                if self.test_proxy(proxy):
                    self.working_proxies.append(proxy)
                    return proxy
                else:
                    self.failed_proxies.append(proxy)
        
        return None
    
    def get_proxy_config(self) -> Dict:
        """yt-dlp용 프록시 설정 반환"""
        proxy = self.get_working_proxy()
        if proxy:
            return {
                'proxy': proxy,
                'socket_timeout': 30,
                'retries': 3
            }
        return {}

def create_proxy_ytdl_opts(base_opts: Dict, proxy_config: Dict = None) -> Dict:
    """프록시를 포함한 yt-dlp 옵션 생성"""
    opts = base_opts.copy()
    
    if proxy_config:
        opts.update(proxy_config)
    
    # 프록시 관련 추가 설정
    opts.update({
        'socket_timeout': 30,
        'retries': 3,
        'fragment_retries': 3,
        'extractor_retries': 3,
    })
    
    return opts

# 전역 프록시 매니저
proxy_manager = ProxyManager()

def get_proxy_ytdl_opts(base_opts: Dict) -> Dict:
    """프록시를 포함한 yt-dlp 옵션 반환"""
    proxy_config = proxy_manager.get_proxy_config()
    return create_proxy_ytdl_opts(base_opts, proxy_config)
