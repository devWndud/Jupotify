#!/usr/bin/env python3
"""
yt-dlp 테스트 스크립트
YouTube 링크만 넣으면 다운로드되는 간단한 예제
"""

import yt_dlp
import os
import sys

def download_youtube_video(url, output_dir="./downloads"):
    """YouTube 비디오 다운로드"""
    
    # 다운로드 디렉토리 생성
    os.makedirs(output_dir, exist_ok=True)
    
    # yt-dlp 옵션 설정
    ydl_opts = {
        'format': 'bestaudio[ext=m4a]/bestaudio/best',  # 최고 품질 오디오
        'outtmpl': os.path.join(output_dir, '%(title)s.%(ext)s'),  # 출력 파일명
        'noplaylist': True,  # 플레이리스트가 아닌 단일 비디오만
        'extract_flat': False,  # 실제 다운로드
        'quiet': False,  # 진행 상황 출력
        'no_warnings': False,  # 경고 메시지 출력
    }
    
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            print(f"다운로드 시작: {url}")
            
            # 비디오 정보 추출
            info = ydl.extract_info(url, download=False)
            title = info.get('title', 'Unknown')
            duration = info.get('duration', 0)
            uploader = info.get('uploader', 'Unknown')
            
            print(f"제목: {title}")
            print(f"업로더: {uploader}")
            print(f"길이: {duration}초")
            print("-" * 50)
            
            # 실제 다운로드
            ydl.download([url])
            
            print("다운로드 완료!")
            return True
            
    except Exception as e:
        print(f"다운로드 실패: {e}")
        return False

def main():
    """메인 함수"""
    if len(sys.argv) != 2:
        print("사용법: python test_ytdlp.py <YouTube_URL>")
        print("예시: python test_ytdlp.py https://www.youtube.com/watch?v=eefC4-IHZoA")
        return
    
    url = sys.argv[1]
    
    # URL 유효성 검사
    if 'youtube.com' not in url and 'youtu.be' not in url:
        print("올바른 YouTube URL을 입력해주세요.")
        return
    
    print("=" * 60)
    print("YouTube 다운로드 테스트")
    print("=" * 60)
    
    success = download_youtube_video(url)
    
    if success:
        print("\n✅ 다운로드 성공!")
        print("다운로드된 파일은 ./downloads 폴더에 있습니다.")
    else:
        print("\n❌ 다운로드 실패!")
        print("yt-dlp를 최신 버전으로 업데이트해보세요:")
        print("pip install --upgrade yt-dlp")

if __name__ == "__main__":
    main()
