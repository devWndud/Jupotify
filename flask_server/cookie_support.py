#!/usr/bin/env python3
"""
쿠키 지원 모듈
YouTube 로그인 상태를 활용한 차단 우회
"""
import os
import json
import requests
from typing import Dict, Optional

class CookieManager:
    def __init__(self):
        self.cookie_file = 'youtube_cookies.txt'
        self.cookies = {}
        self.load_cookies()
    
    def load_cookies(self):
        """쿠키 파일 로드"""
        if os.path.exists(self.cookie_file):
            try:
                with open(self.cookie_file, 'r') as f:
                    self.cookies = json.load(f)
                print(f"로드된 쿠키 수: {len(self.cookies)}")
            except Exception as e:
                print(f"쿠키 로드 실패: {e}")
    
    def save_cookies(self, cookies: Dict):
        """쿠키 저장"""
        try:
            with open(self.cookie_file, 'w') as f:
                json.dump(cookies, f, indent=2)
            self.cookies = cookies
            print("쿠키 저장 완료")
        except Exception as e:
            print(f"쿠키 저장 실패: {e}")
    
    def get_cookie_config(self) -> Dict:
        """yt-dlp용 쿠키 설정 반환"""
        if self.cookies:
            return {
                'cookiesfrombrowser': None,
                'cookies': self.cookie_file,
                'cookiefile': self.cookie_file
            }
        return {}
    
    def test_cookies(self) -> bool:
        """쿠키 유효성 테스트"""
        try:
            response = requests.get(
                'https://www.youtube.com',
                cookies=self.cookies,
                timeout=10
            )
            return response.status_code == 200
        except:
            return False

def create_cookie_ytdl_opts(base_opts: Dict, cookie_config: Dict = None) -> Dict:
    """쿠키를 포함한 yt-dlp 옵션 생성"""
    opts = base_opts.copy()
    
    if cookie_config:
        opts.update(cookie_config)
    
    return opts

# 전역 쿠키 매니저
cookie_manager = CookieManager()

def get_cookie_ytdl_opts(base_opts: Dict) -> Dict:
    """쿠키를 포함한 yt-dlp 옵션 반환"""
    cookie_config = cookie_manager.get_cookie_config()
    return create_cookie_ytdl_opts(base_opts, cookie_config)

def update_cookies_from_browser():
    """브라우저에서 쿠키 추출 (수동)"""
    print("YouTube 쿠키 추출 방법:")
    print("1. Chrome에서 YouTube에 로그인")
    print("2. F12 개발자 도구 열기")
    print("3. Application > Cookies > https://www.youtube.com")
    print("4. 모든 쿠키를 복사하여 youtube_cookies.txt에 저장")
    print("5. JSON 형식으로 저장: {\"cookie_name\": \"cookie_value\"}")
