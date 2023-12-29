#!/bin/bash

# Requires the following variables
# KUBECTL: kubectl command
# OSMNS: OSM namespace in the cluster vim
# NETNUM: used to select external networks
# VCPE: "pod_id" or "deploy/deployment_id" of the cpd vnf
# VWAN: "pod_id" or "deploy/deployment_id" of the wan vnf
#ADDED: # VCTRL: "pod_id" or "deploy/deployment_id" of the ctrl vnf
# REMOTESITE: the "public" IP of the remote site

set -u # to verify variables are defined
: $KUBECTL
: $OSMNS
: $NETNUM
: $VACC
: $VCPE
: $VWAN
: $VCTRL
: $REMOTESITE

if [[ ! $VCPE =~ "sdedge-ns-repo-cpechart"  ]]; then
    echo ""       
    echo "ERROR: incorrect <cpe_deployment_id>: $VCPE"
    exit 1
fi

if [[ ! $VWAN =~ "sdedge-ns-repo-wanchart"  ]]; then
    echo ""       
    echo "ERROR: incorrect <wan_deployment_id>: $VWAN"
    exit 1
fi

ACC_EXEC="$KUBECTL exec -n $OSMNS $VACC --"
CPE_EXEC="$KUBECTL exec -n $OSMNS $VCPE --"
WAN_EXEC="$KUBECTL exec -n $OSMNS $VWAN --"
CTRL_EXEC="$KUBECTL exec -n $OSMNS $VCTRL --"
WAN_SERV="${VWAN/deploy\//}"
CTRL_SERV="${VCTRL/deploy\//}"

# Router por defecto inicial en k8s (calico)
K8SGW="169.254.1.1"

## 1. Obtener IPs y puertos de las VNFs
echo "## 1. Obtener IPs y puertos de las VNFs"

IPCPE=`$CPE_EXEC hostname -I | awk '{print $1}'`
echo "IPCPE = $IPCPE"

IPWAN=`$WAN_EXEC hostname -I | awk '{print $1}'`
echo "IPWAN = $IPWAN"

IPCTRL=`$CTRL_EXEC hostname -I | awk '{print $1}'`
echo "IPCTRL = $IPCTRL"

PORTWAN=`$KUBECTL get -n $OSMNS -o jsonpath="{.spec.ports[0].nodePort}" service $WAN_SERV`
echo "PORTWAN = $PORTWAN"

PORTCTRL=`$KUBECTL get -n $OSMNS -o jsonpath="{.spec.ports[0].nodePort}" service $CTRL_SERV`
echo "PORTCTRL = $PORTCTRL"

## 2. En VNF:cpe agregar un bridge y sus vxlan
echo "## 2. En VNF:cpe agregar un bridge y configurar IPs y rutas"
$CPE_EXEC ip route add $IPWAN/32 via $K8SGW
$CPE_EXEC ovs-vsctl add-br brwan
$CPE_EXEC ip link add cpewan type vxlan id 5 remote $IPWAN dstport 8741 dev eth0
$CPE_EXEC ovs-vsctl add-port brwan cpewan
$CPE_EXEC ifconfig cpewan up
$CPE_EXEC ip link add sr1sr2 type vxlan id 12 remote $REMOTESITE dstport 8742 dev net$NETNUM
$CPE_EXEC ovs-vsctl add-port brwan sr1sr2
$CPE_EXEC ifconfig sr1sr2 up

## 3. En VNF:wan arrancar controlador SDN"
echo "## 3. En VNF:wan arrancar controlador SDN"
#$WAN_EXEC /usr/local/bin/ryu-manager --verbose flowmanager/flowmanager.py ryu.app.ofctl_rest 2>&1 | tee ryu.log &

#$WAN_EXEC /usr/local/bin/ryu-manager flowmanager/flowmanager.py ryu.app.ofctl_rest ryu.app.simple_switch_13 2>&1 | tee ryu.log &
$CTRL_EXEC /usr/local/bin/ryu-manager ryu.app.simple_switch_13 ryu.app.ofctl_rest ryu.app.rest_qos 2>&1 | tee ryu.log & 

#$WAN_EXEC /usr/local/bin/ryu-manager flowmanager/flowmanager.py ryu.app.qos_simple_switch_13 ryu.app.ofctl_rest ryu.app.rest_qos 2>&1 | tee ryu.log &

## 4. En VNF:wan activar el modo SDN del conmutador y crear vxlan
echo "## 4. En VNF:wan activar el modo SDN del conmutador y crear vxlan"
$WAN_EXEC ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
$WAN_EXEC ovs-vsctl set-fail-mode brwan secure
$WAN_EXEC ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000001
#echo "Set controller"
#$WAN_EXEC ovs-vsctl set-controller brwan tcp:127.0.0.1:6633
echo "##############################"
echo "#### Set controller for WAN switch ####"
$WAN_EXEC ovs-vsctl set-controller brwan tcp:$IPCTRL:6633
echo "##############################"
$WAN_EXEC ip link add cpewan type vxlan id 5 remote $IPCPE dstport 8741 dev eth0
$WAN_EXEC ovs-vsctl add-port brwan cpewan
$WAN_EXEC ifconfig cpewan up

## 4.final_1 En VNF:cpe asignar controlador RYU del VNF:wan"
echo "#########"
echo "## 4.final_1 En VNF:cpe y VNF:acc asignar controlador RYU del VNF:wan"
echo "#########"
echo "#### Config de CPE ####"
$CPE_EXEC ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
$CPE_EXEC ovs-vsctl set-fail-mode brwan secure
$CPE_EXEC ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000002
#echo "Set controller"
#$CPE_EXEC ovs-vsctl set-controller brwan tcp:$IPWAN:6633

echo "##############################"
echo "#### Set controller for CPE switch ####"
$CPE_EXEC ovs-vsctl set-controller brwan tcp:$IPCTRL:6633
echo "##############################"
echo "#### Config de ACCESS ####"
$ACC_EXEC ovs-vsctl set bridge brwan protocols=OpenFlow10,OpenFlow12,OpenFlow13
$ACC_EXEC ovs-vsctl set-fail-mode brwan secure
$ACC_EXEC ovs-vsctl set bridge brwan other-config:datapath-id=0000000000000003
#echo "Set controller"
#$ACC_EXEC ovs-vsctl set-controller brwan tcp:$IPWAN:6633

echo "##############################"
echo "#### Set controller for ACC switch ####"
$ACC_EXEC ovs-vsctl set-controller brwan tcp:$IPCTRL:6633
echo "##############################"
## 5. Aplica las reglas de la sdwan con ryu
echo "## 5. Aplica las reglas de la sdwan con ryu"
#RYU_ADD_URL="http://localhost:$PORTWAN/stats/flowentry/add"
RYU_ADD_URL="http://localhost:$PORTCTRL/stats/flowentry/add"
curl -X POST -d @json/from-cpe.json $RYU_ADD_URL
curl -X POST -d @json/to-cpe.json $RYU_ADD_URL
curl -X POST -d @json/broadcast-from-axs.json $RYU_ADD_URL
curl -X POST -d @json/from-mpls.json $RYU_ADD_URL
curl -X POST -d @json/to-voip-gw.json $RYU_ADD_URL
curl -X POST -d @json/sdedge$NETNUM/to-voip.json $RYU_ADD_URL

echo "--"
echo "sdedge$NETNUM: abrir navegador para ver sus flujos Openflow:"
#echo "firefox http://localhost:$PORTWAN/home/ &"
echo "firefox http://localhost:$PORTCTRL/home/ &"