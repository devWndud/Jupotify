#!/usr/bin/env python3
"""
보안이 강화된 Flask 서버 시작 스크립트
"""
import os
import sys
import logging
from server import app, limiter
from config import Config

def setup_logging():
    """로깅 설정"""
    logging.basicConfig(
        level=getattr(logging, Config.LOG_LEVEL),
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(Config.LOG_FILE),
            logging.StreamHandler(sys.stdout)
        ]
    )

def main():
    """메인 함수"""
    setup_logging()
    logger = logging.getLogger(__name__)
    
    logger.info("보안이 강화된 Flask 서버를 시작합니다...")
    logger.info(f"호스트: {Config.HOST}")
    logger.info(f"포트: {Config.PORT}")
    logger.info(f"Rate Limiting: 활성화")
    logger.info(f"보안 필터: 활성화")
    
    try:
        app.run(
            host=Config.HOST,
            port=Config.PORT,
            debug=False,  # 프로덕션에서는 항상 False
            threaded=True
        )
    except KeyboardInterrupt:
        logger.info("서버가 사용자에 의해 중지되었습니다.")
    except Exception as e:
        logger.error(f"서버 시작 중 오류 발생: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
