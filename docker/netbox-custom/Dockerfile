
FROM netboxcommunity/netbox:v4.4.4-3.4.1

ARG NETBOX_DIODE_PLUGIN_VERSION=1.4.1

RUN /usr/local/bin/pip install --no-cache-dir \
        netbox-diode-plugin==${NETBOX_DIODE_PLUGIN_VERSION}
