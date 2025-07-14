#!/bin/bash
source ./functions.sh

SHORT=rnqs
LONG="regenerate,noop,quit,skip"
OPTS=$(getopt -a -n dockovpn --options $SHORT --longoptions $LONG -- "$@")

if [[ $? -ne 0 ]] ; then
    exit 1
fi

eval set -- "$OPTS"

while :
do
  case "$1" in
    -r | --regenerate)
      REGENERATE="1"
      shift;
      ;;
    -n | --noop)
      NOOP="1"
      shift;
      ;;
    -q | --quit)
      QUIT="1"
      shift;
      ;;
    -s | --skip)
      SKIP="1"
      shift;
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      exit 1
      ;;
  esac
done

ADAPTER="${NET_ADAPTER:=eth0}"
TUN_PORT=${HOST_TUN_PORT:-1194}
TUN_PROTO="${HOST_TUN_PROTO:-udp}"
IPV4_CIDR="${OVPN_IP_NET:-10.8.0.0/24}"


mkdir -p /dev/net

if [ ! -c /dev/net/tun ]; then
    echo "$(datef) Creating tun/tap device."
    mknod /dev/net/tun c 10 200
fi

# Read environment variable ROUTERS
routers_content=${ROUTERS:-""}
# Initialize concatenated string
output_routers=""

# Check if routers_content is empty
if [[ -n "$routers_content" ]]; then
  # Use commas to split the content and concatenate
  IFS=',' read -ra ADDR <<< "$routers_content"
  for item in "${ADDR[@]}"; do
    output_routers+="push \"route $item 255.255.255.0 vpn_gateway\"\n"
  done
fi

if [ -f ./addroutes.sh ]; then
  source ./addroutes.sh
fi

# Replace variables in ovpn config file
sed -i 's/%HOST_TUN_PROTOCOL%/'"$TUN_PROTO"'/g' /etc/openvpn/server.conf
sed -i 's/%TUN_PORT%/'"$TUN_PORT"'/g' /etc/openvpn/server.conf
sed -i 's/%ROUTERS%/'"$output_routers"'/g' /etc/openvpn/server.conf

# write server network by IPV4_CIDR into server.conf
IPV4_SERVER="server $(ipcalc -4 -a $IPV4_CIDR | sed  's/^ADDRESS*=//') $(ipcalc  -4 -m $IPV4_CIDR  | sed  's/^NETMASK*=//')"
sed  -i "s/^server.*/$IPV4_SERVER/g" /etc/openvpn/server.conf

# Allow UDP traffic on port 1194 or set environment variables HOST_TUN_PROTO and HOST_TUN_PORT.
iptables -A INPUT -i $ADAPTER -p $TUN_PROTO -m state --state NEW,ESTABLISHED --dport $TUN_PORT -j ACCEPT
iptables -A OUTPUT -o $ADAPTER -p $TUN_PROTO -m state --state ESTABLISHED --sport $TUN_PORT -j ACCEPT

# Allow traffic on the TUN interface.
iptables -A INPUT -i tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

# Allow forwarding traffic only from the VPN (set environment variables OVPN_IP_NET).
iptables -A FORWARD -i tun0 -o $ADAPTER -s $IPV4_CIDR -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -A POSTROUTING -s $IPV4_CIDR -o $ADAPTER -j MASQUERADE

cd "$APP_PERSIST_DIR"

LOCKFILE=.gen

# Regenerate certs only on the first start
if [ ! -f $LOCKFILE ]; then
    IS_INITIAL="1"
    test -d pki || REGENERATE="1"
    if [[ -n $REGENERATE ]]; then
        easyrsa --batch init-pki
        easyrsa --batch gen-dh
        # DH parameters of size 2048 created at /usr/share/easy-rsa/pki/dh.pem
        # Copy DH file
        cp pki/dh.pem /etc/openvpn
    fi

    easyrsa build-ca nopass << EOF

EOF
    # CA creation complete and you may now import and sign cert requests.
    # Your new CA certificate file for publishing is at:
    # /opt/Dockovpn_data/pki/ca.crt

    easyrsa gen-req MyReq nopass << EOF2

EOF2
    # Keypair and certificate request completed. Your files are:
    # req: /opt/Dockovpn_data/pki/reqs/MyReq.req
    # key: /opt/Dockovpn_data/pki/private/MyReq.key

    easyrsa sign-req server MyReq << EOF3
yes
EOF3
    # Certificate created at: /opt/Dockovpn_data/pki/issued/MyReq.crt

    openvpn --genkey --secret ta.key << EOF4
yes
EOF4

    easyrsa --days=$CRL_DAYS gen-crl

    touch $LOCKFILE
fi

# Regenereate CRL on each startup, with a 10 years expiry
EASYRSA_CRL_DAYS=3650 easyrsa gen-crl

# We need to check if a renew of the server certificate is required
# The server certificate is valid for 14 days, or custom variable CERTAGE
[ -z "$CERTAGE"] && CERTAGE=14
echo "Checking if the server certificate is still valid"
openssl x509 -in pki/issued/MyReq.crt -checkend $(( ${CERTAGE} * 86400 )) -noout
if [ $? -eq 0 ]; then
    echo "Server Certificate is still valid"
else
    echo "Server Certificate is expired, regenerating"
    mv -f pki/issued/MyReq.crt pki/issued/MyReq.crt.old
    # Renew the certificate
    easyrsa --batch sign-req server MyReq
fi

# Copy initial configuration and scripts if /etc/openvpn is empty
# Allows /etc/openvpn to be mapped to persistent volume
if [[ ! -f /etc/openvpn/server.conf ]]; then
    cp /etc/openvpn.template/* /etc/openvpn/
fi

# Keep dh.pem - either the one generated on build or the persistent one - if missing
if [ ! -f pki/dh.pem ] ; then 
    if [ -f /etc/openvpn/dh.pem ] ; then
        echo "Copying dh.pem from /etc/openvpn"
        cp /etc/openvpn/dh.pem pki/dh.pem
    fi
fi
# Copy server keys and certificates
cp pki/dh.pem pki/ca.crt pki/issued/MyReq.crt pki/private/MyReq.key pki/crl.pem ta.key /etc/openvpn

cd "$APP_INSTALL_PATH"

# Print app version
getVersionFull

if ! [[ -n $NOOP ]]; then
    # Need to feed key password
    openvpn --config /etc/openvpn/server.conf &

    if [[ -n $IS_INITIAL ]]; then
        # By some strange reason we need to do echo command to get to the next command
        echo " "

        if ! [[ -n $SKIP ]]; then
          # Generate client config
          generateClientConfig $@ &
        else
          echo "$(datef) SKIP is set: skipping client generation"
        fi
    else
      echo "$(datef) Data exist: skipping client generation"
    fi
fi

if ! [[ -n $QUIT ]]; then
    tail -f /dev/null
fi
