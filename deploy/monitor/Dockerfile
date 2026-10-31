# TalkChief Cowork Meetings: server monitoring to Sentry (see monitor.py).
FROM python:3.12-slim
RUN pip install --no-cache-dir sentry-sdk==2.19.2
COPY monitor.py /monitor.py
LABEL org.opencontainers.image.title="TalkChief Cowork Meetings monitor"
CMD ["python", "-u", "/monitor.py"]
