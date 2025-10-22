#!/usr/bin/env python3
"""
간단한 yt-dlp 테스트
"""

import yt_dlp

# 테스트할 YouTube URL
url = "https://www.youtube.com/watch?v=_RHUKysNB2g&list=RDCGvIzFRcRMA&index=8"

# yt-dlp 옵션
ydl_opts = {
    'format': 'bestaudio[ext=m4a]/bestaudio/best',
    'outtmpl': '%(title)s.%(ext)s',
    'noplaylist': True,
}

try:
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        print(f"다운로드 시작: {url}")
        ydl.download([url])
        print("다운로드 완료!")
except Exception as e:
    print(f"오류: {e}")
