#!/bin/bash

domain_name="example.com"

. functions.sh

setup_domain()
{
    domains=$(maas ${maas_profile} domains read)

    my_domain=$(echo $domains | jq '.[] | select(.name=="'${domain_name}'")')

    if [[ -z $my_domain ]] ; then

        maas ${maas_profile} domains create name=${domain_name}
    fi
}

get_ip_from_juju()
{
    from_app=""

    case $dns_name in
        "landscape")
            juju_name="landscape-haproxy"
            from_app="true"
            model="-m lma"
            ;;
        "graylog"|"nagios")
            juju_name=${dns_name}
            from_app="true"
            model="-m lma"
            ;;
	"dashboard")
            juju_name="openstack-dashboard"
            ;;
	"mysql")
            juju_name="mysql-innodb-cluster"
            ;;
	"neutron")
            juju_name="neutron-api"
            ;;
	"nova")
            juju_name="nova-cloud-controller"
            ;;
        *)
            juju_name=${dns_name}
            ;;
    esac

    [[ -n "$from_app" ]] && juju status ${model} ${juju_name} --format json | jq .applications[\"${juju_name}\"].units[][\"public-address\"] | sed s/\"//g
    [[ -z "$from_app" ]] && juju config ${model} ${juju_name} vip

}

add_record()
{
    dns_name=$1
    maas_dns_ip=$2

    dns_name_result=$(maas ${maas_profile} dnsresources read name=${dns_name}-internal)

    if [[ -n $(echo $dns_name_result | jq .[]) ]] ; then

        dns_id=$(echo $dns_name_result | jq .[].id)
        dns_ip=$(maas ${maas_profile} dnsresource update ${dns_id} fqdn=${dns_name}-internal.${domain_name} ip_addresses=${maas_dns_ip})
    else
        dns_ip=$(maas ${maas_profile} dnsresources create fqdn=${dns_name}-internal.${domain_name} ip_addresses=${maas_dns_ip})
    fi

    dns_cname_result=$(maas ${maas_profile} dnsresource-records read rrtype=CNAME name=${dns_name})

    if [[ -n $(echo $dns_cname_result | jq .[]) ]] ; then

        dns_id=$(echo $dns_cname_result | jq .[].id)
        dns_cname=$(maas ${maas_profile} dnsresource-record update ${dns_id} rrtype=cname rrdata=${dns_name}-internal.${domain_name}.)
    else
        dns_cname=$(maas ${maas_profile} dnsresource-records create fqdn=${dns_name}.${domain_name} rrtype=cname rrdata=${dns_name}-internal.${domain_name}.)
    fi

}

do_rmq_nodes()
{
    rmq_ips=$(juju status --format json | jq -rc '.applications["rabbitmq-server"].units | to_entries[] | .value["public-address"]')
    i=1

    for ip in ${rmq_ips}
    do
        dns_name=rabbit-${i}
        add_record ${dns_name} ${ip}
        (( i++ ))
    done
}

read_configs
maas_login

setup_domain

for app in ${maas_dns_names[*]} landscape graylog nagios ; do
    add_record ${app} $(get_ip_from_juju $dns_name)
done

do_rmq_nodes
