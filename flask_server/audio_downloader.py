#!/usr/bin/env python3
"""
실제 오디오 파일 다운로드 모듈
YouTube에서 오디오 스트림을 직접 다운로드합니다.
"""
import os
import re
import json
import requests
from urllib.parse import urlparse, parse_qs, unquote
from typing import Dict, Optional, Tuple
import tempfile
import subprocess

class AudioDownloader:
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
    
    def get_audio_stream_url(self, video_id: str) -> Optional[str]:
        """오디오 스트림 URL 추출"""
        try:
            url = f"https://www.youtube.com/watch?v={video_id}"
            response = self.session.get(url, timeout=15)
            
            if response.status_code != 200:
                return None
            
            content = response.text
            
            # 다양한 패턴으로 오디오 스트림 URL 찾기
            audio_patterns = [
                r'"audioQuality":"AUDIO_QUALITY_MEDIUM".*?"url":"([^"]+)"',
                r'"audioQuality":"AUDIO_QUALITY_HIGH".*?"url":"([^"]+)"',
                r'"mimeType":"audio/mp4".*?"url":"([^"]+)"',
                r'"mimeType":"audio/webm".*?"url":"([^"]+)"',
                r'"formatId":"140".*?"url":"([^"]+)"',
                r'"formatId":"251".*?"url":"([^"]+)"',
            ]
            
            for pattern in audio_patterns:
                match = re.search(pattern, content)
                if match:
                    # URL 디코딩
                    audio_url = match.group(1).replace('\\u0026', '&')
                    audio_url = unquote(audio_url)
                    return audio_url
            
            return None
            
        except Exception as e:
            print(f"Audio stream extraction error: {e}")
            return None
    
    def download_audio_file(self, video_id: str, output_dir: str) -> Optional[Tuple[str, str]]:
        """오디오 파일 다운로드"""
        try:
            # 1. 오디오 스트림 URL 추출
            audio_url = self.get_audio_stream_url(video_id)
            if not audio_url:
                print("No audio stream URL found")
                return None
            
            print(f"Found audio stream: {audio_url[:100]}...")
            
            # 2. 직접 다운로드 시도
            try:
                response = self.session.get(audio_url, stream=True, timeout=30)
                if response.status_code == 200:
                    # 파일 저장
                    filename = f"{video_id}.m4a"
                    filepath = os.path.join(output_dir, filename)
                    
                    with open(filepath, 'wb') as f:
                        for chunk in response.iter_content(chunk_size=8192):
                            if chunk:
                                f.write(chunk)
                    
                    print(f"Audio downloaded: {filepath}")
                    return filepath, filename
                else:
                    print(f"HTTP error: {response.status_code}")
                    return None
                    
            except Exception as e:
                print(f"Direct download failed: {e}")
                return None
                
        except Exception as e:
            print(f"Download error: {e}")
            return None
    
    def download_with_ytdlp(self, url: str, output_dir: str) -> Optional[Tuple[str, str]]:
        """yt-dlp를 사용한 다운로드 (백업 방법)"""
        try:
            import yt_dlp
            
            ydl_opts = {
                'format': 'bestaudio[ext=m4a]/bestaudio/best',
                'outtmpl': os.path.join(output_dir, '%(title)s-%(id)s.%(ext)s'),
                'noplaylist': True,
                'quiet': True,
                'no_warnings': True,
                'extract_flat': False,
                'writethumbnail': False,
            }
            
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=True)
                
                # 다운로드된 파일 찾기
                for file in os.listdir(output_dir):
                    if file.endswith(('.m4a', '.mp3', '.webm')):
                        filepath = os.path.join(output_dir, file)
                        return filepath, file
                
                return None
                
        except Exception as e:
            print(f"yt-dlp download failed: {e}")
            return None

# 전역 인스턴스
audio_downloader = AudioDownloader()

def download_audio_file(url: str, output_dir: str) -> Optional[Tuple[str, str]]:
    """오디오 파일 다운로드 (메인 함수)"""
    video_id = audio_downloader.extract_video_id(url)
    if not video_id:
        return None
    
    # 1. 직접 스트림 다운로드 시도
    result = audio_downloader.download_audio_file(video_id, output_dir)
    if result:
        return result
    
    # 2. yt-dlp 백업 시도
    result = audio_downloader.download_with_ytdlp(url, output_dir)
    if result:
        return result
    
    return None
