
from flask import Flask, request, jsonify, send_from_directory, url_for, abort
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import yt_dlp
import os
import re
import json
import subprocess
import tempfile
import logging
from datetime import datetime, timedelta
from collections import defaultdict
import time
import shutil
from alternative_downloader import get_video_info_alternative, extract_video_id

app = Flask(__name__)

# Rate limiting 설정
limiter = Limiter(
    key_func=get_remote_address,
    default_limits=["100 per hour", "10 per minute"]
)
limiter.init_app(app)

# 로깅 설정
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('server.log'),
        logging.StreamHandler()
    ]
)

# 의심스러운 IP 추적
suspicious_ips = defaultdict(list)
BLOCK_THRESHOLD = 10  # 10번 이상 의심스러운 요청 시 차단
BLOCK_DURATION = 3600  # 1시간 차단

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_DIR = os.path.join(BASE_DIR, 'downloads')
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# 보안 미들웨어
@app.before_request
def security_check():
    client_ip = get_remote_address()
    current_time = time.time()
    
    # 의심스러운 요청 패턴 감지
    suspicious_patterns = [
        'powershell', 'cmd', 'bash', 'sh', 'php', 'asp', 'jsp',
        'admin', 'wp-admin', 'wp-content', 'wp-includes',
        'config', 'database', 'backup', 'sql', 'dump',
        'shell', 'exec', 'system', 'eval', 'base64'
    ]
    
    # 요청 경로나 헤더에 의심스러운 패턴이 있는지 확인
    request_path = request.path.lower()
    user_agent = request.headers.get('User-Agent', '').lower()
    
    is_suspicious = any(pattern in request_path or pattern in user_agent 
                       for pattern in suspicious_patterns)
    
    if is_suspicious:
        suspicious_ips[client_ip].append(current_time)
        logging.warning(f"Suspicious request from {client_ip}: {request.method} {request_path}")
        
        # 차단된 IP인지 확인
        if len(suspicious_ips[client_ip]) >= BLOCK_THRESHOLD:
            # 최근 1시간 내 요청만 카운트
            recent_requests = [t for t in suspicious_ips[client_ip] if current_time - t < BLOCK_DURATION]
            if len(recent_requests) >= BLOCK_THRESHOLD:
                logging.warning(f"Blocking suspicious IP: {client_ip}")
                abort(403, description="IP blocked due to suspicious activity")
    
    # 허용된 엔드포인트만 접근 허용
    allowed_endpoints = ['/extract', '/download', '/files/', '/delete', '/version', '/health']
    if not any(request.path.startswith(endpoint) for endpoint in allowed_endpoints):
        logging.info(f"Access to non-allowed endpoint: {request.path} from {client_ip}")
        abort(404)

# 헬스체크 엔드포인트
@app.route('/health')
def health_check():
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat(),
        'version': '1.0.0'
    }), 200

YDL_OPTS = {
    "quiet": True,
    "skip_download": True,
    "nocheckcertificate": True,
    "geo_bypass": True,
    "extract_flat": False,
    "forcejson": True,
    "noplaylist": True,
    "source_address": "0.0.0.0",
    "http_headers": {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "en-US,en;q=0.9,ko;q=0.8",
        "Accept-Encoding": "gzip, deflate, br",
        "DNT": "1",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Cache-Control": "max-age=0",
    },
    "format": "bestaudio/best",
    "extractor_retries": 5,
    "fragment_retries": 5,
    "retries": 5,
    "sleep_interval": 2,
    "max_sleep_interval": 10,
    "sleep_interval_subtitles": 1,
    "sleep_interval_requests": 1,
    "sleep_interval_subtitles": 1,
    "sleep_interval_requests": 1,
    "extractor_args": {
        "youtube": {
            "player_client": ["android_music", "android_creator", "android", "web"],
            "player_skip": ["webpage"],
            "innertube_host": "music.youtube.com",
            "innertube_key": "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30",
        }
    },
}

@app.post("/extract")
def extract():
    data = request.get_json(force=True)
    url = data.get("url", "")
    if not url:
        return jsonify({"error": "missing url"}), 400

    try:
        with yt_dlp.YoutubeDL(YDL_OPTS) as ydl:
            info = ydl.extract_info(url, download=False)
            # If playlist mixed in, pick the first entry
            if "entries" in info and info["entries"]:
                info = info["entries"][0]

            title = info.get("title") or "Unknown"
            author = info.get("uploader") or info.get("channel") or "Unknown"
            duration = info.get("duration")  # seconds
            thumbnail = info.get("thumbnail")

            # Find direct audio URL from formats
            audio_url = None
            ext = None
            formats = info.get("formats") or []
            # Prefer m4a/mp4 first
            preferred = []
            fallback = []
            for f in formats:
                # Only audio
                if f.get("vcodec") in (None, "none"):
                    (preferred if (f.get("ext") in ("m4a", "mp4")) else fallback).append(f)
            selected = None
            if preferred:
                selected = max(preferred, key=lambda x: x.get("abr") or 0)
            elif fallback:
                selected = max(fallback, key=lambda x: x.get("abr") or 0)

            if selected:
                audio_url = selected.get("url")
                ext = selected.get("ext")

            return jsonify({
                "audio_url": audio_url,
                "title": title,
                "author": author,
                "thumbnail_url": thumbnail,
                "ext": ext,
                "duration": duration
            }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def _sanitize(name: str) -> str:
    return re.sub(r"[\\/:*?\"<>|]", "_", name).strip()[:120]


def _run_with_yt_dlp_module(url: str, outdir: str, quality: str = "192"):
    """yt-dlp 모듈을 사용한 다운로드 (download_mp3.py 방식)"""
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
        if isinstance(info, dict) and "entries" in info and info["entries"]:
            # 플레이리스트인 경우 첫 번째 항목 반환
            info = info["entries"][0]
        return info


def _run_with_yt_dlp_exe(url: str, outdir: str, quality: str = "192"):
    """시스템 yt-dlp 실행파일을 사용한 다운로드 (download_mp3.py 방식)"""
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

    logging.info(f"외부 yt-dlp 실행: {' '.join(cmd)}")
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp 프로세스가 코드 {proc.returncode}로 종료되었습니다.")


@app.post("/download")
def download():
    data = request.get_json(force=True)
    url = data.get("url", "")
    if not url:
        return jsonify({"error": "missing url"}), 400

    quality = data.get("quality", "192")  # MP3 품질 (기본 192kbps)
    format_type = data.get("format", "mp3")  # 기본 MP3

    logging.info(f"다운로드 시작: {url}")

    # 방법 1: yt-dlp 모듈 방식 시도 (download_mp3.py 방식)
    try:
        logging.info("→ yt-dlp 파이썬 모듈로 시도합니다...")
        info = _run_with_yt_dlp_module(url, DOWNLOAD_DIR, quality)
        
        # info가 딕셔너리가 아니면 예외 처리
        if not isinstance(info, dict):
            logging.error(f"info 타입 오류: {type(info)}")
            raise TypeError("info is not a dictionary")
        
        title = info.get("title") or "Unknown"
        author = info.get("uploader") or info.get("channel") or "Unknown"
        duration = info.get("duration")
        thumbnail = info.get("thumbnail")
        video_id = info.get("id")

        # 다운로드된 파일 찾기
        sanitized_title = _sanitize(title)
        filename = None
        
        # MP3 파일 찾기
        for f in os.listdir(DOWNLOAD_DIR):
            if sanitized_title in f and f.endswith(".mp3"):
                filename = f
                break
        
        # MP3가 없으면 원본 파일 찾기
        if not filename:
            for f in os.listdir(DOWNLOAD_DIR):
                if sanitized_title in f or (video_id and video_id in f):
                    filename = f
                    break

        if not filename:
            logging.error(f"파일을 찾을 수 없습니다. 다운로드 디렉토리: {DOWNLOAD_DIR}")
            return jsonify({"error": "file not found after download"}), 500

        # Build public URL
        base_url = request.host_url.rstrip('/')
        file_url = f"{base_url}/files/{filename}"

        logging.info(f"다운로드 완료 (모듈 방식): {filename}")
        return jsonify({
            "file_url": file_url,
            "title": title,
            "author": author,
            "thumbnail_url": thumbnail,
            "ext": "mp3",
            "duration": duration,
            "method": "module"
        }), 200

    except Exception as e_mod:
        logging.error(f"모듈 방식 실패: {str(e_mod)}")
        logging.error(f"에러 타입: {type(e_mod)}")
        import traceback
        logging.error(traceback.format_exc())

        # 방법 2: yt-dlp 실행파일 방식 시도
        try:
            logging.info("→ 시스템 yt-dlp 실행파일로 시도합니다...")
            _run_with_yt_dlp_exe(url, DOWNLOAD_DIR, quality)
            
            # 실행파일 방식은 정보 추출이 별도로 필요
            with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True}) as ydl:
                info = ydl.extract_info(url, download=False)
                if "entries" in info and info["entries"]:
                    info = info["entries"][0]

            title = info.get("title") or "Unknown"
            author = info.get("uploader") or info.get("channel") or "Unknown"
            duration = info.get("duration")
            thumbnail = info.get("thumbnail")
            sanitized_title = _sanitize(title)

            # 파일 찾기
            filename = None
            for f in os.listdir(DOWNLOAD_DIR):
                if sanitized_title in f and f.endswith(".mp3"):
                    filename = f
                    break

            if not filename:
                return jsonify({"error": "file not found after download"}), 500

            base_url = request.host_url.rstrip('/')
            file_url = f"{base_url}/files/{filename}"

            logging.info(f"다운로드 완료 (실행파일 방식): {filename}")
            return jsonify({
                "file_url": file_url,
                "title": title,
                "author": author,
                "thumbnail_url": thumbnail,
                "ext": "mp3",
                "duration": duration,
                "method": "executable"
            }), 200

        except Exception as e_exe:
            logging.error(f"실행파일 방식 실패: {str(e_exe)}")

            # 방법 3: 기존 방식으로 폴백
            try:
                logging.info("→ 기존 방식으로 폴백합니다...")
                ydl_opts = {
                    "format": "bestaudio[ext=m4a]/bestaudio/best",
                    "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
                    "noplaylist": True,
                    "quiet": False,
                    "no_warnings": False,
                }

                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info = ydl.extract_info(url, download=True)
                    if "entries" in info and info["entries"]:
                        info = info["entries"][0]

                title = info.get("title") or "Unknown"
                author = info.get("uploader") or info.get("channel") or "Unknown"
                duration = info.get("duration")
                thumbnail = info.get("thumbnail")
                ext = info.get("ext")

                base = f"{_sanitize(title)}-{info.get('id')}"
                filename = None
                for f in os.listdir(DOWNLOAD_DIR):
                    if f.startswith(base) and f.endswith(f".{ext}"):
                        filename = f
                        break
                if not filename:
                    vid = info.get("id")
                    for f in os.listdir(DOWNLOAD_DIR):
                        if f.endswith(f".{ext}") and (vid in f):
                            filename = f
                            break
                if not filename:
                    return jsonify({"error": "file not found after download"}), 500

                base_url = request.host_url.rstrip('/')
                file_url = f"{base_url}/files/{filename}"

                logging.info(f"다운로드 완료 (기존 방식): {filename}")
                return jsonify({
                    "file_url": file_url,
                    "title": title,
                    "author": author,
                    "thumbnail_url": thumbnail,
                    "ext": ext,
                    "duration": duration,
                    "method": "fallback"
                }), 200

            except Exception as e_fallback:
                logging.error(f"기존 방식 실패: {str(e_fallback)}")
                
                # 최종 폴백: 비디오 정보만 제공
                try:
                    video_id = extract_video_id(url)
                    if not video_id:
                        return jsonify({"error": "비디오 ID를 추출할 수 없습니다"}), 400
                    
                    alt_info = get_video_info_alternative(video_id)
                    if not alt_info['success']:
                        return jsonify({"error": "비디오 정보를 가져올 수 없습니다"}), 500
                    
                    return jsonify({
                        "error": "다운로드 실패 - 모든 방법 실패",
                        "title": alt_info['title'],
                        "author": alt_info['author'],
                        "thumbnail_url": alt_info['thumbnail'],
                        "video_id": video_id,
                        "suggestion": "yt-dlp 업데이트 또는 VPN 사용을 시도해보세요"
                    }), 503
                    
                except Exception as alt_e:
                    return jsonify({"error": f"모든 방법 실패: {str(alt_e)}"}), 500


@app.get('/files/<path:filename>')
def files(filename):
    return send_from_directory(DOWNLOAD_DIR, filename, as_attachment=False)


@app.post('/delete')
def delete_file():
    data = request.get_json(force=True)
    file_url = data.get('file_url')
    filename = data.get('filename')
    target = None

    try:
        if filename:
            target = os.path.join(DOWNLOAD_DIR, os.path.basename(filename))
        elif file_url:
            # Extract filename part if it matches our /files route
            # e.g., http://host/files/<filename>
            marker = '/files/'
            if marker in file_url:
                candidate = file_url.split(marker, 1)[1]
                target = os.path.join(DOWNLOAD_DIR, os.path.basename(candidate))

        if not target:
            return jsonify({'error': 'missing filename or file_url'}), 400

        # Ensure path is inside DOWNLOAD_DIR
        target = os.path.abspath(target)
        if not target.startswith(os.path.abspath(DOWNLOAD_DIR)):
            return jsonify({'error': 'invalid path'}), 400

        if os.path.exists(target):
            os.remove(target)
        return jsonify({'status': 'ok'}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.get('/version')
def get_version():
    """Check app version and return update info if needed"""
    try:
        # Read version info from version.json
        version_file = os.path.join(BASE_DIR, 'version.json')
        if os.path.exists(version_file):
            with open(version_file, 'r', encoding='utf-8') as f:
                version_info = json.load(f)
        else:
            # Default version info
            version_info = {
                "latest_version": "1.0.0",
                "min_version": "1.0.0",
                "update_available": False,
                "force_update": False,
                "download_url": "",
                "release_notes": "Initial release"
            }
        
        # Get client version from query param
        client_version = request.args.get('version', '1.0.0')
        
        # Simple version comparison (assumes semantic versioning)
        def version_tuple(v):
            return tuple(map(int, v.split('.')))
        
        latest_version = version_info.get('latest_version', '1.0.0')
        min_version = version_info.get('min_version', '1.0.0')
        
        client_tuple = version_tuple(client_version)
        latest_tuple = version_tuple(latest_version)
        min_tuple = version_tuple(min_version)
        
        # Check if update is needed
        needs_update = client_tuple < latest_tuple
        force_update = client_tuple < min_tuple
        
        response = {
            "current_version": client_version,
            "latest_version": latest_version,
            "min_version": min_version,
            "update_available": needs_update,
            "force_update": force_update,
            "download_url": version_info.get('download_url', ''),
            "release_notes": version_info.get('release_notes', ''),
        }
        
        return jsonify(response), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == "__main__":
    # pip install flask yt-dlp
    # python server.py
    app.run(host="0.0.0.0", port=8080)
    