#!/usr/bin/env python3
"""
download_mp3.py

사용법:
    python download_mp3.py <youtube_url_or_playlist> [output_dir]

설명:
- yt-dlp 파이썬 모듈이 설치되어 있으면 모듈 방식으로 다운로드/변환.
- 모듈이 없고 시스템에 yt-dlp 실행파일이 있으면, 그걸로 subprocess 실행.
- ffmpeg가 PATH에 있어야 mp3 변환이 정상 동작함.
- 다수 URL 지원 (공백으로 구분하거나 텍스트 파일에서 읽는 옵션 추가 가능).
"""

import sys
import os
import shutil
import subprocess
import re

def sanitize_name(name: str) -> str:
    return re.sub(r'[\\/:"*?<>|]+', '_', name).strip()

def run_with_yt_dlp_module(url: str, outdir: str, quality: str = "192"):
    try:
        from yt_dlp import YoutubeDL
    except Exception as e:
        raise RuntimeError("yt_dlp 모듈을 불러올 수 없습니다.") from e

    # 출력 템플릿: outdir/<title>.mp3
    outtmpl = os.path.join(outdir, "%(title)s.%(ext)s")

    ydl_opts = {
        'format': 'bestaudio/best',
        'outtmpl': outtmpl,
        'noplaylist': False,  # 플레이리스트면 여러개 받을 수 있음
        'quiet': False,
        'no_warnings': True,
        'retries': 3,
        'continuedl': True,
        'ffmpeg_location': None,  # 필요 시 절대경로 지정
        'postprocessors': [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': 'mp3',
            'preferredquality': quality,
        }],
        # 필요하면 cookie나 proxy 옵션 추가 가능
    }

    with YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=True)
        # info가 playlist인 경우엔 여러 항목 처리됨
        if isinstance(info, dict) and info.get('title'):
            title = sanitize_name(info.get('title'))
            print(f"완료: {title}.mp3")
        else:
            print("다운로드/변환 완료.")

def run_with_yt_dlp_exe(url: str, outdir: str, quality: str = "192"):
    # 시스템에서 yt-dlp 실행파일을 찾는다.
    exe_name = shutil.which("yt-dlp") or shutil.which("yt-dlp.exe")
    if not exe_name:
        raise RuntimeError("시스템에서 yt-dlp 실행파일을 찾을 수 없습니다. (pip 설치 또는 실행파일 배치 필요)")

    # 커맨드라인: yt-dlp -x --audio-format mp3 --audio-quality 192K -o "<outdir/%(title)s.%(ext)s>" <url>
    outtmpl = os.path.join(outdir, "%(title)s.%(ext)s")
    cmd = [
        exe_name,
        "-x",
        "--audio-format", "mp3",
        "--audio-quality", f"{quality}K",
        "-o", outtmpl,
        url
    ]

    print("외부 yt-dlp 실행:", " ".join(cmd))
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp 프로세스가 코드 {proc.returncode}로 종료되었습니다.")

def ensure_outdir(dirpath: str):
    if not os.path.exists(dirpath):
        os.makedirs(dirpath, exist_ok=True)

def main():
    if len(sys.argv) < 2:
        print("Usage: python download_mp3.py <youtube_url_or_playlist> [output_dir]")
        sys.exit(1)

    url = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) >= 3 else "."
    outdir = os.path.abspath(outdir)
    ensure_outdir(outdir)

    # 사용자에게 환경 체크 정보 출력
    print("출력 폴더:", outdir)
    print("URL:", url)
    print("ffmpeg in PATH?", shutil.which("ffmpeg") is not None)

    # 우선 모듈 방식 시도
    try:
        print("\n→ yt-dlp 파이썬 모듈로 시도합니다...")
        run_with_yt_dlp_module(url, outdir)
        print("완료 (모듈 방식).")
        return
    except Exception as e_mod:
        print("모듈 방식 실패:", str(e_mod))

    # 모듈 방식 실패하면 실행파일 방식 시도
    try:
        print("\n→ 시스템 yt-dlp 실행파일로 시도합니다...")
        run_with_yt_dlp_exe(url, outdir)
        print("완료 (실행파일 방식).")
        return
    except Exception as e_exe:
        print("실행파일 방식 실패:", str(e_exe))

    # 둘 다 실패하면 안내
    print("\nERROR: 다운로드 실패")
    print("조치사항:")
    print("1) yt-dlp 파이썬 모듈 설치: python -m pip install -U yt-dlp")
    print("2) 또는 최신 yt-dlp 실행파일(Windows용 .exe)을 https://github.com/yt-dlp/yt-dlp/releases 에서 받아서 PATH에 두거나 스크립트 디렉토리에 복사")
    print("3) ffmpeg가 설치되어 있고 PATH에 있는지 확인: ffmpeg -version")
    print("4) 만약 YouTube에서 403 오류가 난다면 yt-dlp 최신버전(혹은 nightly)을 사용하고, 필요시 Deno 설치가 요구될 수 있음(yt-dlp 개발 지침 참조).")

if __name__ == "__main__":
    main()
