
FROM netboxcommunity/netbox:v4.4.4-3.4.1

COPY --from=ghcr.io/astral-sh/uv:0.8 /uv /usr/local/bin/

ARG NETBOX_DIODE_PLUGIN_VERSION=1.4.1

RUN VIRTUAL_ENV=/opt/netbox/venv \
    /usr/local/bin/uv pip install \
        --no-cache \
        netboxlabs-diode-netbox-plugin==${NETBOX_DIODE_PLUGIN_VERSION}
