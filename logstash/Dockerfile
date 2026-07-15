ARG LOGSTASH_VERSION=8.9.0
FROM opensearchproject/logstash-oss-with-opensearch-output-plugin:${LOGSTASH_VERSION}

# The base image ships a sample pipeline; replace it with ours.
# Copy the single file, not the directory: Logstash concatenates every *.conf in
# pipeline/ into one pipeline, so a stray file would duplicate inputs/outputs.
RUN rm -f /usr/share/logstash/pipeline/logstash.conf
COPY --chown=logstash:logstash pipeline/logstash.conf /usr/share/logstash/pipeline/logstash.conf

EXPOSE 5960/udp
EXPOSE 9600