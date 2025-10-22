#!/usr/bin/env python3
"""
대체 YouTube 다운로더 - yt-dlp가 실패할 때 사용
"""

import requests
import re
import json
import os
from urllib.parse import urlparse, parse_qs

def extract_video_id(url):
    """YouTube URL에서 비디오 ID 추출"""
    patterns = [
        r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([^&\n?#]+)',
        r'youtube\.com/v/([^&\n?#]+)',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return None

def get_video_info_alternative(video_id):
    """대체 방법으로 비디오 정보 가져오기"""
    try:
        # YouTube oEmbed API 사용
        oembed_url = f"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={video_id}&format=json"
        
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
        }
        
        response = requests.get(oembed_url, headers=headers, timeout=10)
        if response.status_code == 200:
            data = response.json()
            return {
                'title': data.get('title', 'Unknown'),
                'author': data.get('author_name', 'Unknown'),
                'thumbnail': data.get('thumbnail_url', ''),
                'success': True
            }
    except Exception as e:
        print(f"oEmbed API 실패: {e}")
    
    # 대체 방법: 페이지에서 직접 추출
    try:
        url = f"https://www.youtube.com/watch?v={video_id}"
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept-Encoding': 'gzip, deflate, br',
            'DNT': '1',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
        }
        
        response = requests.get(url, headers=headers, timeout=15)
        if response.status_code == 200:
            content = response.text
            
            # 제목 추출
            title_match = re.search(r'"title":"([^"]+)"', content)
            title = title_match.group(1).replace('\\u0026', '&') if title_match else 'Unknown'
            
            # 채널명 추출
            author_match = re.search(r'"author":"([^"]+)"', content)
            author = author_match.group(1).replace('\\u0026', '&') if author_match else 'Unknown'
            
            # 썸네일 추출
            thumbnail_match = re.search(r'"thumbnail":\{"thumbnails":\[.*?"url":"([^"]+)"', content)
            thumbnail = thumbnail_match.group(1) if thumbnail_match else ''
            
            return {
                'title': title,
                'author': author,
                'thumbnail': thumbnail,
                'success': True
            }
    except Exception as e:
        print(f"페이지 파싱 실패: {e}")
    
    return {
        'title': 'Unknown',
        'author': 'Unknown', 
        'thumbnail': '',
        'success': False
    }

def download_with_ytdlp_fallback(video_id, output_dir):
    """yt-dlp 대체 방법으로 다운로드 시도"""
    import subprocess
    import tempfile
    
    try:
        # 임시 디렉토리에서 다운로드
        with tempfile.TemporaryDirectory() as temp_dir:
            cmd = [
                'yt-dlp',
                '--extract-flat', 'false',
                '--format', 'bestaudio[ext=m4a]/bestaudio/best',
                '--output', os.path.join(temp_dir, '%(title)s.%(ext)s'),
                '--no-playlist',
                f'https://www.youtube.com/watch?v={video_id}'
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            
            if result.returncode == 0:
                # 다운로드된 파일 찾기
                for file in os.listdir(temp_dir):
                    if file.endswith(('.m4a', '.mp3', '.webm', '.ogg')):
                        src = os.path.join(temp_dir, file)
                        dst = os.path.join(output_dir, file)
                        os.rename(src, dst)
                        return dst
            else:
                print(f"yt-dlp 실패: {result.stderr}")
                
    except Exception as e:
        print(f"대체 다운로드 실패: {e}")
    
    return None

if __name__ == "__main__":
    # 테스트
    video_id = "eefC4-IHZoA"
    info = get_video_info_alternative(video_id)
    print(f"비디오 정보: {info}")
