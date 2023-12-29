FROM osrg/ryu

COPY qos_simple_switch_13.py /ryu/ryu/app/qos_simple_switch_13.py

RUN apt-get clean
RUN apt-get update && apt-get install -y \
    net-tools \
    iproute \
    inetutils-ping \
    openvswitch-switch \
    openvswitch-common \
    iperf \
    tcpdump \
    python-pip \
    git
RUN pip install -r tools/optional-requires
RUN git clone https://github.com/martimy/flowmanager.git
