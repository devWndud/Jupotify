#!/usr/bin/env python3
"""
직접 YouTube 정보 추출기
DNS 문제를 우회하여 YouTube 비디오 정보를 직접 추출합니다.
"""
import re
import json
import requests
from urllib.parse import urlparse, parse_qs
from typing import Dict, Optional

class DirectYouTubeExtractor:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'ko-KR,ko;q=0.9,en;q=0.8',
            'Accept-Encoding': 'gzip, deflate, br',
            'Connection': 'keep-alive',
        })
    
    def extract_video_id(self, url: str) -> Optional[str]:
        """URL에서 비디오 ID 추출"""
        patterns = [
            r'(?:v=|\/)([0-9A-Za-z_-]{11}).*',
            r'(?:embed\/)([0-9A-Za-z_-]{11})',
            r'(?:watch\?v=)([0-9A-Za-z_-]{11})',
        ]
        
        for pattern in patterns:
            match = re.search(pattern, url)
            if match:
                return match.group(1)
        return None
    
    def get_video_info_direct(self, video_id: str) -> Dict:
        """직접 YouTube 페이지에서 정보 추출"""
        try:
            # YouTube 페이지 직접 접근
            url = f"https://www.youtube.com/watch?v={video_id}"
            response = self.session.get(url, timeout=15)
            
            if response.status_code != 200:
                return {"success": False, "error": f"HTTP {response.status_code}"}
            
            # 페이지에서 JSON 데이터 추출
            content = response.text
            
            # ytInitialPlayerResponse 패턴 찾기
            pattern = r'var ytInitialPlayerResponse = ({.*?});'
            match = re.search(pattern, content)
            
            if not match:
                return {"success": False, "error": "ytInitialPlayerResponse not found"}
            
            try:
                player_data = json.loads(match.group(1))
            except json.JSONDecodeError:
                return {"success": False, "error": "JSON decode error"}
            
            # 비디오 정보 추출
            video_details = player_data.get('videoDetails', {})
            
            title = video_details.get('title', 'Unknown')
            author = video_details.get('author', 'Unknown')
            duration = int(video_details.get('lengthSeconds', 0))
            
            # 썸네일 URL 추출
            thumbnail_url = video_details.get('thumbnail', {}).get('thumbnails', [])
            if thumbnail_url:
                thumbnail = thumbnail_url[-1].get('url', '')
            else:
                thumbnail = ''
            
            return {
                "success": True,
                "title": title,
                "author": author,
                "duration": duration,
                "thumbnail": thumbnail,
                "video_id": video_id
            }
            
        except requests.exceptions.RequestException as e:
            return {"success": False, "error": f"Request error: {str(e)}"}
        except Exception as e:
            return {"success": False, "error": f"Unexpected error: {str(e)}"}
    
    def extract_audio_url(self, video_id: str) -> Optional[str]:
        """오디오 URL 추출 (간단한 방법)"""
        try:
            # YouTube 페이지에서 스트림 정보 추출
            url = f"https://www.youtube.com/watch?v={video_id}"
            response = self.session.get(url, timeout=15)
            
            if response.status_code != 200:
                return None
            
            content = response.text
            
            # 오디오 스트림 URL 패턴 찾기
            audio_patterns = [
                r'"audioQuality":"AUDIO_QUALITY_MEDIUM".*?"url":"([^"]+)"',
                r'"audioQuality":"AUDIO_QUALITY_HIGH".*?"url":"([^"]+)"',
                r'"mimeType":"audio/mp4".*?"url":"([^"]+)"',
            ]
            
            for pattern in audio_patterns:
                match = re.search(pattern, content)
                if match:
                    # URL 디코딩
                    audio_url = match.group(1).replace('\\u0026', '&')
                    return audio_url
            
            return None
            
        except Exception as e:
            print(f"Audio URL extraction error: {e}")
            return None

# 전역 인스턴스
direct_extractor = DirectYouTubeExtractor()

def extract_video_info_direct(url: str) -> Dict:
    """직접 YouTube 정보 추출"""
    video_id = direct_extractor.extract_video_id(url)
    if not video_id:
        return {"success": False, "error": "Video ID not found"}
    
    return direct_extractor.get_video_info_direct(video_id)

def extract_audio_url_direct(url: str) -> Optional[str]:
    """직접 오디오 URL 추출"""
    video_id = direct_extractor.extract_video_id(url)
    if not video_id:
        return None
    
    return direct_extractor.extract_audio_url(video_id)
