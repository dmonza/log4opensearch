ARG DASHBOARDS_VERSION=2.19.2
FROM opensearchproject/opensearch-dashboards:${DASHBOARDS_VERSION}

# DEV-FIRST: the security plugin is removed because the OpenSearch node runs with
# DISABLE_SECURITY_PLUGIN=true. To run secured, drop this line and see README > Security.
RUN /usr/share/opensearch-dashboards/bin/opensearch-dashboards-plugin remove securityDashboards

COPY --chown=opensearch-dashboards:opensearch-dashboards \
     opensearch_dashboards.yml /usr/share/opensearch-dashboards/config/

# FROM opensearchproject/opensearch-dashboards:3
# RUN /usr/share/opensearch-dashboards/bin/opensearch-dashboards-plugin remove securityDashboards
# COPY --chown=opensearch-dashboards:opensearch-dashboards opensearch_dashboards.yml /usr/share/opensearch-dashboards/config/