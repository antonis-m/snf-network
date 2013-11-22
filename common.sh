#!/bin/bash

function try {

  $1 &>/dev/null || true 

}

function clear_routed_setup_ipv4 {

 arptables -D OUTPUT -o $INTERFACE --opcode request -j mangle
 while ip rule del dev $INTERFACE; do :; done
 iptables -D FORWARD -i $INTERFACE -p udp --dport 67 -j DROP

}

function clear_routed_setup_ipv6 {

 while ip -6 rule del dev $INTERFACE; do :; done

}


function clear_routed_setup_firewall {

  for oldchain in protected unprotected limited; do
    iptables  -D FORWARD -o $INTERFACE -j $oldchain
    ip6tables -D FORWARD -o $INTERFACE -j $oldchain
  done

}

function clear_ebtables {

  runlocked $RUNLOCKED_OPTS ebtables -D FORWARD -i $INTERFACE -j $FROM
  runlocked $RUNLOCKED_OPTS ebtables -D FORWARD -o $INTERFACE -j $TO
  #runlocked $RUNLOCKED_OPTS ebtables -D OUTPUT -o $INTERFACE -j $TO

  runlocked $RUNLOCKED_OPTS ebtables -X $FROM
  runlocked $RUNLOCKED_OPTS ebtables -X $TO
}


function clear_nfdhcpd {

  rm $NFDHCPD_STATE_DIR/$INTERFACE

}


function routed_setup_ipv4 {

	# mangle ARPs to come from the gw's IP
	arptables -A OUTPUT -o $INTERFACE --opcode request -j mangle --mangle-ip-s    "$NETWORK_GATEWAY"

	# route interface to the proper routing table
	ip rule add dev $INTERFACE table $TABLE

	# static route mapping IP -> INTERFACE
	ip route replace $IP proto static dev $INTERFACE table $TABLE

	# Enable proxy ARP
	echo 1 > /proc/sys/net/ipv4/conf/$INTERFACE/proxy_arp
}

function routed_setup_ipv6 {
	# Add a routing entry for the eui-64
	prefix=$NETWORK_SUBNET6
	uplink=$(ip -6 route list table $TABLE | grep "default via" | awk '{print $5}')
	eui64=$($MAC2EUI64 $MAC $prefix)


	ip -6 rule add dev $INTERFACE table $TABLE
	ip -6 ro replace $eui64/128 dev $INTERFACE table $TABLE
	ip -6 neigh add proxy $eui64 dev $uplink

	# disable proxy NDP since we're handling this on userspace
	# this should be the default, but better safe than sorry
	echo 0 > /proc/sys/net/ipv6/conf/$INTERFACE/proxy_ndp
}

# pick a firewall profile per NIC, based on tags (and apply it)
function routed_setup_firewall {
	# for latest ganeti there is no need to check other but uuid
	ifprefixindex="synnefo:network:$INTERFACE_INDEX:"
	ifprefixname="synnefo:network:$INTERFACE_NAME:"
	ifprefixuuid="synnefo:network:$INTERFACE_UUID:"
	for tag in $TAGS; do
		tag=${tag#$ifprefixindex}
		tag=${tag#$ifprefixname}
		tag=${tag#$ifprefixuuid}
		case $tag in
		protected)
			chain=protected
		;;
		unprotected)
			chain=unprotected
		;;
		limited)
			chain=limited
		;;
		esac
	done

	if [ "x$chain" != "x" ]; then
		iptables  -A FORWARD -o $INTERFACE -j $chain
		ip6tables -A FORWARD -o $INTERFACE -j $chain
	fi
}

function init_ebtables {

  runlocked $RUNLOCKED_OPTS ebtables -N $FROM
  runlocked $RUNLOCKED_OPTS ebtables -A FORWARD -i $INTERFACE -j $FROM
  runlocked $RUNLOCKED_OPTS ebtables -N $TO
  runlocked $RUNLOCKED_OPTS ebtables -A FORWARD -o $INTERFACE -j $TO

}


function setup_ebtables {

  # do not allow changes in ip-mac pair
  if [ -n "$IP"]; then
    runlocked $RUNLOCKED_OPTS ebtables -A $FROM --ip-source \! $IP -p ipv4 -j DROP
  fi
  runlocked $RUNLOCKED_OPTS ebtables -A $FROM -s \! $MAC -j DROP
  #accept dhcp responses from host (nfdhcpd)
  runlocked $RUNLOCKED_OPTS ebtables -A $TO -p ipv4 --ip-protocol=udp  --ip-destination-port=68 -j ACCEPT
  # allow only packets from the same mac prefix
  runlocked $RUNLOCKED_OPTS ebtables -A $TO -s \! $MAC/$MAC_MASK -j DROP
}

function setup_masq {

  # allow packets from/to router (for masquerading)
  # runlocked $RUNLOCKED_OPTS ebtables -A $TO -s $NODE_MAC -j ACCEPT
  # runlocked $RUNLOCKED_OPTS ebtables -A INPUT -i $INTERFACE -j $FROM
  # runlocked $RUNLOCKED_OPTS ebtables -A OUTPUT -o $INTERFACE -j $TO
  return

}

function setup_nfdhcpd {
	umask 022
  FILE=$NFDHCPD_STATE_DIR/$INTERFACE
  #IFACE is the interface from which the packet seems to arrive
  #needed in bridged mode where the packets seems to arrive from the
  #bridge and not from the tap
	cat >$FILE <<EOF
INDEV=$INDEV
IP=$IP
MAC=$MAC
HOSTNAME=$INSTANCE
TAGS="$TAGS"
GATEWAY=$NETWORK_GATEWAY
SUBNET=$NETWORK_SUBNET
GATEWAY6=$NETWORK_GATEWAY6
SUBNET6=$NETWORK_SUBNET6
EUI64=$($MAC2EUI64 $MAC $NETWORK_SUBNET6 2>/dev/null)
EOF

}

