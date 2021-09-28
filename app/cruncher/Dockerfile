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
    iputils-ping \
    jq

ARG AWS_REGION=eu-central-1
ENV AWS_REGION=$AWS_REGION
COPY . /src
WORKDIR /src
ENTRYPOINT ["/src/crunch.sh"]
