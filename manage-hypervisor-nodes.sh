#!/bin/bash

# set -x
. functions.sh

# Time between building VMs
build_fanout=60

# Adds all the subnets, vlans and therefore bridges to the hypervisor, all
# based on the configuration from hypervisor.config and/or default.config
maas_assign_networks()
{
    system_id=$1

    # Get the details of the physical interface
    phsy_int=$(maas ${maas_profile} interfaces read ${system_id} | jq -c ".[] | {id:.id, name:.name,parent:.parents}" | grep "parent.*\[\]")
    phys_int_name=$(echo $phsy_int | jq -r .name)
    phys_int_id=$(echo $phsy_int | jq -r .id)

    i=0
    for vlan in ${vlans[*]}
    do
        subnet_line=$(maas admin subnets read | jq -rc --arg vlan "$vlan" ".[] | select(.vlan.vid == $vlan) | select(.name | contains(\"/24\"))| {subnet_id:.id, vlan_id:.vlan.id, cidr: .cidr}")
        maas_vlan_id=$(echo $subnet_line | jq -r .vlan_id)
        maas_subnet_id=$(echo $subnet_line | jq -r .subnet_id)
        sub_prefix=$(echo $subnet_line | jq -r .cidr | sed 's/0\/24//g')
        ip_addr=""
        if [[ $i -eq 0 ]] ; then
            # Set the first interface to be static as per the configuration so that it
            # consistent over re-provisioning of the system
            vlan_int_id=${phys_int_id}
            mode="STATIC"
            ip_addr="ip_address=$hypervisor_ip"
        else
            # Check to see if the vlan interface already exists, otherwise create it
            vlan_int_id=$(maas ${maas_profile} interfaces read ${system_id} | jq --argjson vlan ${vlan} '.[] | select(.vlan.vid == $vlan) | select(.type == "vlan") | .id')
            if [[ -z "$vlan_int_id" ]] ; then
                vlan_int=$(maas ${maas_profile} interfaces create-vlan ${system_id} vlan=${maas_vlan_id} parent=$phys_int_id)
                vlan_int_id=$(echo $vlan_int | jq -r .id)
            fi
            if [[ $vlan -eq $external_vlan ]] ; then
                # Set the external IP to be static as per the configuration
                mode="STATIC"
                ip_addr="ip_address=$external_ip"
            else
                # Set everything else to be auto assigned
                mode="STATIC"
                ip_addr="ip_address=${sub_prefix}${ip_suffix}"
            fi
        fi
        # Check to see if the bridge interface already exists, otherwise create it
        bridge_int=$(maas ${maas_profile} interfaces read ${system_id} | jq --argjson vlan ${vlan} '.[] | select(.vlan.vid == $vlan) | select(.type == "bridge")')
        [[ -z "${bridge_int}" ]] && bridge_int=$(maas ${maas_profile} interfaces create-bridge ${system_id} name=${bridges[$i]} vlan=$maas_vlan_id mac_address=${hypervisor_mac} parent=$vlan_int_id bridge_tyepe=${bridge_type})
        bridge_int_id=$(echo $bridge_int | jq -r .id)
        cur_mode=$(echo $bridge_int | jq -r ".links[].mode")
        # If the mode is already set correctly, then move on
        [[ $cur_mode == "auto" ]] && [[ $mode == "AUTO" ]] && continue
        #bridge_unlink=$(maas ${maas_profile} interface unlink-subnet $system_id $bridge_int_id id=$( echo $bridge_int_id | jq {maas_subnet_id})
        bridge_link=$(maas ${maas_profile} interface link-subnet $system_id $bridge_int_id mode=${mode} subnet=${maas_subnet_id} ${ip_addr})
        echo $bridge_link
        (( i++ ))
    done
}

maas_create_partitions()
{
    system_id=$1

    disks=$(maas ${maas_profile} block-devices read ${system_id})

    size=20

    actual_size=$(( $size * 1024 * 1024 * 1024 ))

    boot_disk=$(echo $disks | jq ".[] | select(.name == \"${disk_names[0]}\") | .id")

    set_boot_disk=$(maas ${maas_profile} block-device set-boot-disk ${system_id} ${boot_disk})

    storage_layout=$(maas ${maas_profile} machine set-storage-layout ${system_id} storage_layout=lvm vg_name=${hypervisor_name} lv_name=root lv_size=${actual_size} root_disk=${boot_disk})

    vg_device=$(echo $storage_layout | jq ".volume_groups[].id" )
    remaining_space=$(maas ${maas_profile} volume-group read ${system_id} ${vg_device} | jq -r ".available_size")

    libvirt_lv=$(maas ${maas_profile} volume-group create-logical-volume ${system_id} ${vg_device} name=libvirt size=${remaining_space})
    libvirt_block_id=$(echo ${libvirt_lv} | jq -r .id)

    stg_fs=$(maas ${maas_profile} block-device format ${system_id} ${libvirt_block_id} fstype=ext4)

    stg_mount=$(maas ${maas_profile} block-device mount ${system_id} ${libvirt_block_id} mount_point=${ceph_storage_path})

    for ((disk=1;disk<${#disk_names[@]};disk++)); do

        disk_id=$(echo $disks | jq -r ".[] | select(.name == \"${disk_names[$disk]}\") | .id")

        create_partition=$(maas ${maas_profile} partitions create ${system_id} ${disk_id})

        part_id=$(echo $create_partition | jq -r .id)

        if [[ $disk -eq 1 ]] ; then
            vg_create=$(maas ${maas_profile} volume-groups create ${system_id} name=${hypervisor_name}-nvme block_device=${disk_id} partitions=${part_id})

            vg_id=$(echo $vg_create | jq -r .id)
            vg_size=$(echo $vg_create | jq -r .size)
        else

            vg_update=$(maas ${maas_profile} volume-group update ${system_id} ${vg_id} add_partitions=${part_id})
            vg_size=$(echo $vg_update | jq -r .size)
        fi

    done

    lv_create=$(maas admin volume-group create-logical-volume ${system_id} ${vg_id} name=images size=${vg_size})
    lv_id=$(echo $lv_create | jq -r .id)
    lv_fs=$(maas ${maas_profile} block-device format ${system_id} ${lv_id} fstype=ext4)
    lv_mount=$(maas ${maas_profile} block-device mount ${system_id} ${lv_id} mount_point=${storage_path})
}

maas_add_pod()
{
    pod_create=$(maas ${maas_profile} pods create power_address="qemu+ssh://${virsh_user}@${hypervisor_ip}/system" power_user="${virsh_user}" power_pass="${qemu_password}" type="virsh")
    pod_id=$(echo $pod_create | jq -r .id)
    pod_name=$(maas ${maas_profile} pod update ${pod_id} name=${hypervisor_name})
}

# Calls the functions that destroys and cleans up all the VMs
wipe_node() {
    install_deps
    maas_login
    destroy_node
}

create_node() {
    install_deps
    maas_login
    maas_add_node ${hypervisor_name} ${hypervisor_mac} physical
}

install_node() {
    install_deps
    maas_login
    deploy_node
    maas_add_pod
}

add_pod()
{
    install_deps
    maas_login
    maas_add_pod
}

# Fixes all the networks on all the VMs
network_auto()
{
    install_deps
    maas_login

    system_id=$(maas_system_id ${hypervisor_name})
    maas_assign_networks ${system_id}
}

# Fixes all the networks on all the VMs
create_partitions()
{
    install_deps
    maas_login

    system_id=$(maas_system_id ${hypervisor_name})
    maas_create_partitions ${system_id}
}

# The purpose of this function is to stop, release the nodes and wipe the disks
destroy_node() {
    pod_id=$(maas_pod_id ${hypervisor_name})
    pod_delete=$(maas ${maas_profile} pod delete ${pod_id})

    system_id=$(maas_system_id ${hypervisor_name})
    machine_delete=$(maas ${maas_profile} machine delete ${system_id})
}

deploy_node() {
    system_id=$(maas_system_id ${hypervisor_name})
    maas ${maas_profile} machine deploy ${system_id} user_data="$(base64 user-data.yaml)" > /dev/null

    # Only return when the node has finised deploying
    ensure_machine_in_state ${system_id} "Deployed"
}

show_help() {
  echo "

  -a <node>   Create and Deploy
  -c <node>   Creates Hypervisor
  -d <node>   Deploy Hypervisor
  -k <node>   Add Hypervisor as Pod
  -n <node>   Assign Networks
  -p <node>   Update Partitioning
  -w <node>   Removes Hypervisor
  "
}

read_configs

while getopts ":c:w:d:a:k:n:p:" opt; do
  case $opt in
    c)
        read_config "configs/$OPTARG.config"
        create_node
        ;;
    w)
        read_config "configs/$OPTARG.config"
        wipe_node
        ;;
    d)
        read_config "configs/$OPTARG.config"
        install_node
        ;;
    a)
        read_config "configs/$OPTARG.config"
        create_node
        install_node
        ;;
    k)
        read_config "configs/$OPTARG.config"
        add_pod
        ;;
    n)
        read_config "configs/$OPTARG.config"
        network_auto
        ;;
    p)
        read_config "configs/$OPTARG.config"
        create_partitions
        ;;
    \?)
        printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
        show_help
        exit 1
        ;;
    : )
        printf "Option -%s needs an argument.\n" "$OPTARG" >&2
        show_help
        echo ""
        exit 1
  esac
done
