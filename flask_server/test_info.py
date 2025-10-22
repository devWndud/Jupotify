#!/usr/bin/env python3
"""
yt-dlp로 비디오 정보만 가져오기 테스트
"""

import yt_dlp

# 테스트할 YouTube URL
url = "https://www.youtube.com/watch?v=eefC4-IHZoA"

# 정보만 가져오는 옵션
ydl_opts = {
    'quiet': True,
    'no_warnings': True,
    'extract_flat': False,
}

try:
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        print(f"비디오 정보 가져오기: {url}")
        info = ydl.extract_info(url, download=False)
        
        print(f"제목: {info.get('title', 'Unknown')}")
        print(f"업로더: {info.get('uploader', 'Unknown')}")
        print(f"길이: {info.get('duration', 0)}초")
        print(f"조회수: {info.get('view_count', 0)}")
        print(f"썸네일: {info.get('thumbnail', 'None')}")
        
        # 사용 가능한 포맷 확인
        formats = info.get('formats', [])
        audio_formats = [f for f in formats if f.get('vcodec') == 'none']
        
        print(f"\n사용 가능한 오디오 포맷: {len(audio_formats)}개")
        for fmt in audio_formats[:5]:  # 처음 5개만 표시
            print(f"  - {fmt.get('ext')} ({fmt.get('abr', 0)}kbps)")
            
except Exception as e:
    print(f"오류: {e}")
    print("yt-dlp를 업데이트해보세요: pip install --upgrade yt-dlp")
