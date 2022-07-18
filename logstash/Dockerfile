FROM opensearchproject/logstash-oss-with-opensearch-output-plugin:7.16.2
RUN rm -f /usr/share/logstash/pipeline/logstash.conf
ADD pipeline/ /usr/share/logstash/pipeline/
# ADD config/ /usr/share/logstash/config/