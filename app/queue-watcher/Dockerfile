FROM python:3.9.6

ENV DEBIAN_FRONTEND=noninteractive

ARG AWSCLI_VERSION=2.2.7
RUN echo "AWSCLI_VERSION: ${AWSCLI_VERSION}" \
    && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && aws --version \
    && rm -rf ./aws awscliv2.zip
ENV AWS_PAGER ""

RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext \
    jq
    # Note: gettext is probably needed by envsubst

ARG KUBECTL_VERSION=v1.20.5
RUN echo "KUBECTL_VERSION: ${KUBECTL_VERSION}" \
    && curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && kubectl version --client \
    && rm kubectl

COPY . /src
WORKDIR /src
