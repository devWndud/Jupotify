# Flask 서버 보안 설정
import os

class Config:
    # 기본 설정
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'your-secret-key-here'
    
    # Rate Limiting 설정
    RATELIMIT_STORAGE_URL = os.environ.get('RATELIMIT_STORAGE_URL') or 'memory://'
    
    # 보안 설정
    BLOCK_THRESHOLD = int(os.environ.get('BLOCK_THRESHOLD', 10))
    BLOCK_DURATION = int(os.environ.get('BLOCK_DURATION', 3600))
    
    # 로깅 설정
    LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')
    LOG_FILE = os.environ.get('LOG_FILE', 'server.log')
    
    # 서버 설정
    HOST = os.environ.get('HOST', '0.0.0.0')
    PORT = int(os.environ.get('PORT', 8080))
    
    # 허용된 엔드포인트
    ALLOWED_ENDPOINTS = [
        '/extract', '/download', '/files/', '/delete', '/version', '/health'
    ]
    
    # 의심스러운 패턴
    SUSPICIOUS_PATTERNS = [
        'powershell', 'cmd', 'bash', 'sh', 'php', 'asp', 'jsp',
        'admin', 'wp-admin', 'wp-content', 'wp-includes',
        'config', 'database', 'backup', 'sql', 'dump',
        'shell', 'exec', 'system', 'eval', 'base64'
    ]
