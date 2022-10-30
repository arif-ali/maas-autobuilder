#!/bin/bash

. configs/maas.config

for subnet in ${maas_subnets[*]} ; do
    maas "${maas_profile}" ipranges create type=reserved comment="Servers" start_ip="${subnet}.241" end_ip="${subnet}.254"
done

maas "${maas_profile}" ipranges create type=reserved comment="OpenStack VIPs" start_ip="${maas_ip_range}.211" end_ip="${maas_ip_range}.225"
