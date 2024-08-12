# Usa la imagen base de OpenSearch
FROM opensearchproject/opensearch:2.16.0

# Cambia al usuario root para tener los permisos necesarios
USER root

# Define la versión de OpenSearch Dashboards que deseas instalar
ENV OPENSEARCH_DASHBOARDS_VERSION=2.16.0

# Instala dependencias necesarias usando yum
RUN yum -y update && \
    yum -y install curl && \
    yum clean all

# Descarga e instala OpenSearch Dashboards
RUN curl -L https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/${OPENSEARCH_DASHBOARDS_VERSION}/opensearch-dashboards-${OPENSEARCH_DASHBOARDS_VERSION}-linux-x64.tar.gz \
    | tar -xz -C /usr/share && \
    mv /usr/share/opensearch-dashboards-${OPENSEARCH_DASHBOARDS_VERSION} /usr/share/opensearch-dashboards

# Establece el directorio de trabajo
WORKDIR /usr/share/opensearch-dashboards

# Exponer el puerto de OpenSearch Dashboards
EXPOSE 5601

# Configurar el comando de inicio para OpenSearch Dashboards
CMD ["./bin/opensearch-dashboards"]
