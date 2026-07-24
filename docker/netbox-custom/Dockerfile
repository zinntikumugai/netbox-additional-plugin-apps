
FROM netboxcommunity/netbox:v4.6.5-5.0.2

COPY --from=ghcr.io/astral-sh/uv:0.8 /uv /usr/local/bin/

ARG NETBOX_DIODE_PLUGIN_VERSION=1.14.1
ARG NETBOX_BGP_VERSION=0.19.0

RUN VIRTUAL_ENV=/opt/netbox/venv \
    /usr/local/bin/uv pip install \
        --no-cache \
        netboxlabs-diode-netbox-plugin==${NETBOX_DIODE_PLUGIN_VERSION} \
        netbox-bgp==${NETBOX_BGP_VERSION}
