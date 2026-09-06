FROM python:3.12-slim
WORKDIR /app
COPY relay.py .
VOLUME /data
ENV MTC_PORT=8080 MTC_DATA_DIR=/data
EXPOSE 8080
CMD ["python3", "relay.py"]
