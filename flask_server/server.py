
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
from alternative_downloader import get_video_info_alternative, extract_video_id
from proxy_support import get_proxy_ytdl_opts
from cookie_support import get_cookie_ytdl_opts

app = Flask(__name__)

# Rate limiting 설정
limiter = Limiter(
    app,
    key_func=get_remote_address,
    default_limits=["100 per hour", "10 per minute"]
)

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

# 고급 YouTube 설정
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
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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
        "Sec-Ch-Ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": '"Windows"',
    },
    "format": "bestaudio[ext=m4a]/bestaudio/best",
    "extractor_retries": 3,
    "fragment_retries": 3,
    "retries": 3,
    "sleep_interval": 1,
    "max_sleep_interval": 5,
    "sleep_interval_subtitles": 1,
    "sleep_interval_requests": 1,
    "extractor_args": {
        "youtube": {
            "player_client": ["android_music", "android_creator", "android", "web"],
            "player_skip": ["webpage"],
            "innertube_host": "music.youtube.com",
            "innertube_key": "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30",
            "skip": ["dash", "hls"],
            "lang": ["ko", "en"],
        }
    },
    "cookiesfrombrowser": None,  # 쿠키 사용 안함
    "no_check_certificate": True,
    "prefer_insecure": True,
    "verbose": False,
}

# 대체 설정 (더 공격적인 우회)
YDL_OPTS_AGGRESSIVE = {
    "quiet": True,
    "skip_download": True,
    "nocheckcertificate": True,
    "geo_bypass": True,
    "extract_flat": False,
    "forcejson": True,
    "noplaylist": True,
    "source_address": "0.0.0.0",
    "http_headers": {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Accept": "*/*",
        "Accept-Language": "ko-KR,ko;q=0.9,en;q=0.8",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    },
    "format": "bestaudio[ext=m4a]/bestaudio/best",
    "extractor_retries": 2,
    "fragment_retries": 2,
    "retries": 2,
    "sleep_interval": 0.5,
    "max_sleep_interval": 2,
    "extractor_args": {
        "youtube": {
            "player_client": ["ios", "android_music", "android_creator"],
            "player_skip": ["webpage"],
            "innertube_host": "music.youtube.com",
            "innertube_key": "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30",
            "skip": ["dash", "hls"],
            "lang": ["ko", "en"],
        }
    },
    "no_check_certificate": True,
    "prefer_insecure": True,
    "verbose": False,
}

# 프록시 지원 설정
YDL_OPTS_PROXY = get_proxy_ytdl_opts(YDL_OPTS)

# 쿠키 지원 설정
YDL_OPTS_COOKIE = get_cookie_ytdl_opts(YDL_OPTS)

# 프록시 + 쿠키 조합 설정
YDL_OPTS_PROXY_COOKIE = get_proxy_ytdl_opts(get_cookie_ytdl_opts(YDL_OPTS))

@app.post("/extract")
@limiter.limit("5 per minute")
def extract():
    data = request.get_json(force=True)
    url = data.get("url", "")
    if not url:
        return jsonify({"error": "missing url"}), 400

    # 다중 시도 로직 (차단 우회 방법 포함)
    configs = [
        ("standard", YDL_OPTS),
        ("aggressive", YDL_OPTS_AGGRESSIVE),
        ("proxy", YDL_OPTS_PROXY),
        ("cookie", YDL_OPTS_COOKIE),
        ("proxy_cookie", YDL_OPTS_PROXY_COOKIE),
    ]
    
    last_error = None
    
    for config_name, config in configs:
        try:
            logging.info(f"Trying {config_name} configuration for {url}")
            with yt_dlp.YoutubeDL(config) as ydl:
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

                logging.info(f"Success with {config_name} configuration")
                return jsonify({
                    "audio_url": audio_url,
                    "title": title,
                    "author": author,
                    "thumbnail_url": thumbnail,
                    "ext": ext,
                    "duration": duration,
                    "method": config_name
                }), 200
                
        except Exception as e:
            last_error = e
            logging.warning(f"{config_name} configuration failed: {str(e)}")
            continue
    
    # 모든 설정이 실패한 경우
    logging.error(f"All extraction methods failed for {url}")
    return jsonify({
        "error": f"모든 추출 방법 실패: {str(last_error)}",
        "suggestion": "YouTube가 yt-dlp를 차단하고 있습니다. VPN 사용을 권장합니다."
    }), 503


def _sanitize(name: str) -> str:
    return re.sub(r"[\\/:*?\"<>|]", "_", name).strip()[:120]


@app.post("/download")
@limiter.limit("3 per minute")
def download():
    data = request.get_json(force=True)
    url = data.get("url", "")
    if not url:
        return jsonify({"error": "missing url"}), 400

    # 다운로드용 설정들 (차단 우회 방법 포함)
    download_configs = [
        ("standard", {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": False,
            "no_warnings": False,
            **YDL_OPTS
        }),
        ("aggressive", {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": False,
            "no_warnings": False,
            **YDL_OPTS_AGGRESSIVE
        }),
        ("proxy", {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": False,
            "no_warnings": False,
            **YDL_OPTS_PROXY
        }),
        ("cookie", {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": False,
            "no_warnings": False,
            **YDL_OPTS_COOKIE
        }),
        ("proxy_cookie", {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(DOWNLOAD_DIR, "%(title).80s-%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": False,
            "no_warnings": False,
            **YDL_OPTS_PROXY_COOKIE
        })
    ]

    last_error = None
    
    for config_name, ydl_opts in download_configs:
        try:
            logging.info(f"Trying {config_name} download for {url}")
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=True)
                if "entries" in info and info["entries"]:
                    info = info["entries"][0]

                title = info.get("title") or "Unknown"
                author = info.get("uploader") or info.get("channel") or "Unknown"
                duration = info.get("duration")
                thumbnail = info.get("thumbnail")
                ext = info.get("ext")

                # Resolve output filename
                base = f"{_sanitize(title)}-{info.get('id')}"
                filename = None
                for f in os.listdir(DOWNLOAD_DIR):
                    if f.startswith(base) and f.endswith(f".{ext}"):
                        filename = f
                        break
                if not filename:
                    # Fallback: scan by id
                    vid = info.get("id")
                    for f in os.listdir(DOWNLOAD_DIR):
                        if f.endswith(f".{ext}") and (vid in f):
                            filename = f
                            break
                if not filename:
                    return jsonify({"error": "file not found after download"}), 500

                # Build public URL
                base_url = request.host_url.rstrip('/')
                file_url = f"{base_url}/files/{filename}"

                logging.info(f"Success with {config_name} download")
                return jsonify({
                    "file_url": file_url,
                    "title": title,
                    "author": author,
                    "thumbnail_url": thumbnail,
                    "ext": ext,
                    "duration": duration,
                    "method": config_name
                }), 200
                
        except Exception as e:
            last_error = e
            logging.warning(f"{config_name} download failed: {str(e)}")
            continue
    
    # 모든 다운로드 방법이 실패한 경우
    logging.error(f"All download methods failed for {url}")
    
    # 대체 방법: 비디오 ID 추출 후 정보만 가져오기
    try:
        video_id = extract_video_id(url)
        if not video_id:
            return jsonify({"error": "비디오 ID를 추출할 수 없습니다"}), 400
        
        # 대체 방법으로 비디오 정보 가져오기
        alt_info = get_video_info_alternative(video_id)
        if not alt_info['success']:
            return jsonify({"error": "비디오 정보를 가져올 수 없습니다"}), 500
        
        # 임시 파일 생성 (실제 다운로드는 불가능하지만 정보는 제공)
        return jsonify({
            "error": "다운로드 실패 - YouTube가 yt-dlp를 차단하고 있습니다",
            "title": alt_info['title'],
            "author": alt_info['author'],
            "thumbnail_url": alt_info['thumbnail'],
            "video_id": video_id,
            "suggestion": "VPN 사용 또는 다른 서버를 사용해보세요",
            "method": "alternative_info_only"
        }), 503
        
    except Exception as alt_e:
        return jsonify({
            "error": f"모든 방법 실패: {str(last_error)}",
            "suggestion": "YouTube가 yt-dlp를 차단하고 있습니다. VPN 사용을 권장합니다."
        }), 500


@app.get('/files/<path:filename>')
@limiter.limit("20 per minute")
def files(filename):
    return send_from_directory(DOWNLOAD_DIR, filename, as_attachment=False)


@app.post('/delete')
@limiter.limit("10 per minute")
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
    