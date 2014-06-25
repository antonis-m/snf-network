.. snf-network documentation master file, created by
   sphinx-quickstart on Wed Feb 12 20:00:16 2014.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Welcome to snf-network's documentation!
=======================================

snf-network is a set of scripts that handle the network configuration of
an instance inside a Ganeti cluster. It takes advantage of the
variables that Ganeti exports to their execution environment and issue
all the necessary commands to ensure network connectivity to the instance
based on the requested setup.

Environment
-----------

Ganeti supports `IP pool management
<http://docs.ganeti.org/ganeti/master/html/design-network.html>`_
so that end-user can put instances inside networks and get all information
related to the network in scripts. Specifically the following options are
exported:

* IP
* MAC
* MODE
* LINK

are per NIC specific, whereas:

* NETWORK_SUBNET
* NETWORK_GATEWAY
* NETWORK_MAC_PREFIX
* NETWORK_TAGS
* NETWORK_SUBNET6
* NETWORK_GATEWAY6

are inherited by the network in which a NIC resides (optional).

Scripts
-------

The scripts can be divided into two categories:

1. The scripts that are invoked explicitly by Ganeti upon NIC creation.

2. The scripts that are invoked by Ganeti Hooks Manager before or after an
   opcode execution.

The first group has the exact NIC info that is about to be configured where
the latter one has the info of the whole instance. The big difference is that
instance configuration (from the master perspective) might vary or be total
different from the one that is currently running. The reason is that some
modifications can take place without hotplugging.


kvm-ifup-custom
^^^^^^^^^^^^^^^

Ganeti upon instance startup and NIC hotplugging creates the TAP devices to
reflect to the instance's NICs. After that it invokes the Ganeti's `kvm-ifup`
script with the TAP name as first argument and an environment including
all NIC's and the corresponding network's info. This script searches for
a user provided one under `/etc/ganeti/kvm-ifup-custom` and executes it
instead.


kvm-ifdown-custom
^^^^^^^^^^^^^^^^^

In order to cleanup or modify the node's setup or the configuration of an
external component, Ganeti upon instance shutdown, successful instance
migration on source node and NIC hot-unplug invokes `kvm-ifdown` script
with the TAP name as first argument and a boolean second argument pointing
whether we want to do local cleanup only (in case of instance migration) or
totally unconfigure the interface along with e.g., any DNS entries (in case
of NIC hot-unplug). This script searches for a user provided one under
`/etc/ganeti/kvm-ifdown-custom` and executes it instead.


vif-custom
^^^^^^^^^^

Ganeti provides a hypervisor parameter that defines the script to be executed
per NIC upon instance startup: `vif-script`. Ganeti provides `vif-ganeti` as
example script which executes `/etc/xen/scripts/vif-custom` if found.


snf-network-hook
^^^^^^^^^^^^^^^^

This hook gets all static info related to an instance from environment variables
and issues any commands needed. It was used to fix node's setup upon migration
when ifdown script was not supported but now it does nothing.


snf-network-dnshook
^^^^^^^^^^^^^^^^^^^

This hook updates an external `DDNS <https://wiki.debian.org/DDNS>`_ setup via
``nsupdate``. Since we add/remove entries during ifup/ifdown scripts, we use
this only during instance remove/shutdown/rename. It does not rely on exported
environment but it queries first the DNS server to obtain current entries and
then it invokes the necessary commands to remove them (and the relevant
reverse ones too).


Supported Setups
----------------

Currently since NICs in Ganeti are not taggable objects, we use network's and
instance's tags to customize each NIC configuration. NIC inherits the network's
tags (if attached to any) and further customization can be achieved with
instance tags e.g. <tag prefix>:<nic uuid or name>:<tag>. In the following
subsections we will mention all supported tags and their reflected underline
setup.


ip-less-routed
^^^^^^^^^^^^^^

This setup has the following characteristics:

* An external gateway on the same collision domain with all nodes on some
  interface (e.g. eth1, eth0.200) is needed.
* Each node is a router for the hosted VMs
* The node itself does not have an IP inside the routed network
* The node does proxy ARP for IPv4 networks
* The node does proxy NDP for IPv6 networks while RA and NA are
* RS and NS are served locally by
  `nfdhcpd <http://www.synnefo.org/docs/nfdhcpd/latest/index.html>`_
  since the VMs are not on the same link with the router.

Lets analyze a simple PING from an instance to an external IP using this setup.
We assume the following:

* ``IP`` is the instance's IP
* ``GW_IP`` is the external router's IP
* ``NODE_IP`` is the node's IP
* ``ARP_IP`` is a dummy IP inside the network needed for proxy ARP

* ``MAC`` is the instance's MAC
* ``TAP_MAC`` is the tap's MAC
* ``DEV_MAC`` is the host's DEV MAC
* ``GW_MAC`` is the external router's MAC

* ``DEV`` is the node's device that the router is visible from
* ``TAP`` is the host interface connected with the instance's eth0

Since we suppose to be on the same link with the router, ARP takes place first:

1) The VM wants to know the GW_MAC. Since the traffic is routed we do proxy ARP.

 - ARP, Request who-has GW_IP tell IP
 - ARP, Reply GW_IP is-at TAP_MAC ``echo 1 > /proc/sys/net/conf/TAP/proxy_arp``
 - So `arp -na` inside the VM shows: ``(GW_IP) at TAP_MAC [ether] on eth0``

2) The host wants to know the GW_MAC. Since the node does **not** have an IP
   inside the network we use the dummy one specified above.

 - ARP, Request who-has GW_IP tell ARP_IP (Created by DEV)
   ``arptables -I OUTPUT -o DEV --opcode 1 -j mangle --mangle-ip-s ARP_IP``
 - ARP, Reply GW_IP is-at GW_MAC

3) The host wants to know MAC so that it can proxy it.

 - We simulate here that the VM sees **only** GW on the link.
 - ARP, Request who-has IP tell GW_IP (Created by TAP)
   ``arptables -I OUTPUT -o TAP --opcode 1 -j mangle --mangle-ip-s GW_IP``
 - So `arp -na` inside the host shows:
   ``(GW_IP) at GW_MAC [ether] on DEV, (IP) at MAC on TAP``

4) GW wants to know who does proxy for IP.

 - ARP, Request who-has IP tell GW_IP
 - ARP, Reply IP is-at DEV_MAC (Created by host's DEV)


With the above we have a working proxy ARP configuration. The rest is done
via simple L3 routing. Lets assume the following:

* ``TABLE`` is the extra routing table
* ``SUBNET`` is the IPv4 subnet where the VM's IP resides

1) Outgoing traffic:

 - Traffic coming out of TAP is routed via TABLE
   ``ip rule add dev TAP table TABLE``
 - TABLE states that default route is GW_IP via DEV
   ``ip route add default via GW_IP dev DEV``

2) Incoming traffic:

 - Packet arrives at router
 - Router knows from proxy ARP that the IP is at DEV_MAC.
 - Router sends Ethernet packet with tgt DEV_MAC
 - Host receives the packet from DEV interface
 - Traffic coming out DEV is routed via TABLE
   ``ip rule add dev DEV table TABLE``
 - Traffic targeting IP is routed to TAP
   ``ip route add IP dev TAP``

3) Host to VM traffic:

 - Impossible if the VM resides in the host
 - Otherwise there is a route for it: ``ip route add SUBNET dev DEV``

The IPv6 setup is pretty similar but instead of proxy ARP we have proxy NDP
and RS and NS coming from TAP are served by nfdhpcd. RA contain network's
prefix and has M flag unset in order the VM to obtain its IP6 via SLAAC and
O flag set to obtain static info (nameservers, domain search list) via DHCPv6
(also served by nfdhcpd).

Again the VM sees on its link local only TAP which is supposed to be the
Router. The host does proxy for IP6 ``ip -6 neigh add EUI64 dev DEV``.

When an interface gets up inside a host we should invalidate all entries
related to its IP among other nodes and the router. For proxy ARP we do
``arpsend -U -c 1 -i IP DEV`` and for proxy NDP we do ``ndsend EUI64 DEV``


private-filtered
^^^^^^^^^^^^^^^^

In order to provide L2 isolation among several VMs we can use ebtables on a
**single** bridge. The infrastructure must provide a physical VLAN or separate
interface shared among all nodes in the cluster. All virtual interfaces will
be bridged on a common bridge (e.g. ``prv0``) and filtering will be done via
ebtables and MAC prefix. The concept is that all interfaces on the same L2
should have the same MAC prefix. MAC prefix uniqueness is guaranteed by
Synnefo and passed to Ganeti as a network option.

To ensure isolation we should allow traffic coming from tap to have specific
source MAC and at the same time allow traffic coming to tap to have a source
MAC in the same MAC prefix. Applying those rules only in FORWARD chain will not
guarantee isolation. The reason is because packets with target MAC a `multicast
address <http://en.wikipedia.org/wiki/Multicast_address>`_ go through INPUT and
OUTPUT chains. To sum up the following ebtables rules are applied:

.. code-block:: console

  # Create new chains
  ebtables -t filter -N FROMTAP5
  ebtables -t filter -N TOTAP5

  # Filter multicast traffic from VM
  ebtables -t filter -A INPUT -i tap5 -j FROMTAP5

  # Filter multicast traffic to VM
  ebtables -t filter -A OUTPUT -o tap5 -j TOTAP5

  # Filter traffic from VM
  ebtables -t filter -A FORWARD -i tap5 -j FROMTAP5
  # Filter traffic to VM
  ebtables -t filter -A FORWARD -o tap5 -j TOTAP5

  # Allow only specific src MAC for outgoing traffic
  ebtables -t filter -A FROMTAP5 -s ! aa:55:66:1a:ae:82 -j DROP
  # Allow only specific src MAC prefix for incoming traffic
  ebtables -t filter -A TOTAP5 -s ! aa:55:60:0:0:0/ff:ff:f0:0:0:0 -j DROP


dns
^^^

snf-network can update an external `DDNS <https://wiki.debian.org/DDNS>`_
server.  `ifup` and `ifdown` scripts, if `dns` network tag is found, will use
`nsupdate` and add/remove entries related to the interface that is being
managed.


Contents:

.. toctree::
   :maxdepth: 2



Indices and tables
==================

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`

